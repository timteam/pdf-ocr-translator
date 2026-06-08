#!/usr/bin/env python3
"""
Traduit un tableau JSON de textes avec des modèles Opus-MT (format Argos/CTranslate2).

Usage : python3 opusmt_translate.py <model_dir1> [<model_dir2>]
  model_dir1 : modèle src→en (ou src→tgt si traduction directe)
  model_dir2 : (optionnel) modèle en→tgt pour le pivot anglais
  stdin      : tableau JSON de chaînes
  stdout     : tableau JSON des traductions (même ordre)
  stderr     : logs de diagnostic + "PROGRESS:done/total" après chaque chunk

Structure attendue dans chaque model_dir :
  model_dir/model/model.bin          — modèle CTranslate2
  model_dir/model/shared_vocabulary* — vocabulaire (txt ou json)
  model_dir/sentencepiece.model      — tokenizer partagé source+cible
"""
import sys
import os
import re
import time
from pathlib import Path

# ── Détection CPU ─────────────────────────────────────────────────────────────

def _physical_cores() -> int:
    try:
        with open('/proc/cpuinfo') as f:
            content = f.read()
        ids = set(re.findall(r'^core id\s*:\s*(\d+)', content, re.MULTILINE))
        if ids:
            return max(1, len(ids))
    except OSError:
        pass
    return max(1, (os.cpu_count() or 4) // 2)

_N_CORES = _physical_cores()
_N_THREADS = str(_N_CORES)
os.environ.setdefault("OMP_NUM_THREADS",      _N_THREADS)
os.environ.setdefault("MKL_NUM_THREADS",      _N_THREADS)
os.environ.setdefault("OPENBLAS_NUM_THREADS", _N_THREADS)

import json
import gc
import unicodedata

_CHUNK_SIZE = 32  # Opus-MT est bien plus léger que NLLB — chunks plus grands

# Caractères invisibles à supprimer (escapes Unicode explicites pour robustesse).
_INVISIBLE_CHARS = frozenset({
    '\u00ad',  # SOFT HYPHEN
    '\u200b',  # ZERO WIDTH SPACE
    '\u200c',  # ZERO WIDTH NON-JOINER
    '\u200d',  # ZERO WIDTH JOINER
    '\u2060',  # WORD JOINER
    '\ufeff',  # BOM / ZERO WIDTH NO-BREAK SPACE
    '\u2061', '\u2062', '\u2063', '\u2064',  # invisible math operators
})

# ▁ U+2581 : marqueur de frontière de mot SentencePiece qui peut fuir du décodage
_SP_BOUNDARY = '\u2581'


def _clean(text: str) -> str:
    """Normalise le texte pour éviter les caractères non supportés par les polices PDF."""
    text = unicodedata.normalize('NFKC', text)
    # Supprime les caractères invisibles
    text = ''.join(ch for ch in text if ch not in _INVISIBLE_CHARS)
    # Remplace ▁ (marqueur SentencePiece) par une espace
    text = text.replace(_SP_BOUNDARY, ' ')
    # Normalise toutes les catégories Unicode d'espace (Zs/Zl/Zp) → espace simple
    text = ''.join(
        ' ' if unicodedata.category(ch) in ('Zs', 'Zl', 'Zp') else ch
        for ch in text
    )
    text = re.sub(r' {2,}', ' ', text)
    # Supprime les artefacts typographiques parasites introduits par le modèle en début de texte
    # (†, ‡ de filets de page ; ' " de bordures ovales ; • · de puces OCR)
    text = re.sub(r'^[†‡‘’“”•·‧]+\s*', '', text)
    return text.strip()


def _split_for_model(text: str, max_chars: int = 80) -> list:
    """PA2 : découpe les textes longs sur les frontières de phrases japonaises.

    Évite d'envoyer des blocs de 200+ caractères au modèle, qui hallucine
    sur les entrées longues contenant plusieurs phrases/paragraphes.
    Sépare sur 。！？ et les sauts de ligne ; regroupe les fragments courts.
    """
    if len(text) <= max_chars:
        return [text]
    parts = re.split(r'(?<=[。！？\n])\s*', text)
    result, current = [], ''
    for part in parts:
        if len(current) + len(part) <= max_chars:
            current += part
        else:
            if current.strip():
                result.append(current.strip())
            current = part
    if current.strip():
        result.append(current.strip())
    return result if result else [text]


def _is_failed_translation(src: str, translated: str) -> bool:
    """PA3 : quality gate multi-critères — détecte une traduction ratée.

    Critères (un seul suffit) :
      1. Densité de '?' > 20 % — modèle produit <unk> en série
      2. Ratio longueur sortie / entrée > 6 — hallucination (sortie anormalement longue)
      3. N-gramme de 2-3 mots répété > 3 fois — modèle boucle
    En cas de détection → le texte source japonais est conservé tel quel.
    """
    t = translated.strip()
    if not t:
        return True
    # Critère 1 : densité de '?'
    if t.count('?') / max(len(t), 1) > 0.20:
        return True
    # Critère 2 : ratio longueur
    src_len = len(src.replace(' ', ''))
    out_len = len(t.replace(' ', ''))
    if src_len > 10 and out_len / max(src_len, 1) > 6:
        return True
    # Critère 3 : n-grammes répétés
    words = t.split()
    if len(words) >= 6:
        for n in (2, 3):
            ngrams = [' '.join(words[k:k + n]) for k in range(len(words) - n + 1)]
            for ng in set(ngrams):
                if ngrams.count(ng) > 3:
                    return True
    return False


def _load_domain_vocab():
    """PA7 : charge le vocabulaire domaine depuis domain_vocab.json.

    Le fichier est recherché dans le même répertoire que ce script.
    Format : [{"pattern": "...", "flags": "i", "replacement": "..."}, ...]
    Retourne une liste de (compiled_regex, replacement).
    """
    vocab_path = Path(__file__).parent / 'domain_vocab.json'
    if not vocab_path.exists():
        return []
    try:
        import json as _json
        entries = _json.loads(vocab_path.read_text(encoding='utf-8'))
        compiled = []
        for e in entries:
            flags = re.IGNORECASE if 'i' in e.get('flags', '') else 0
            compiled.append((re.compile(e['pattern'], flags), e['replacement']))
        _log(f"PA7: {len(compiled)} règle(s) vocabulaire domaine chargée(s)")
        return compiled
    except Exception as exc:
        _log(f"PA7: domain_vocab.json ignoré ({exc})")
        return []


def _apply_domain_vocab(text: str, vocab: list) -> str:
    """PA7 : applique le vocabulaire domaine sur un texte traduit."""
    for pattern, replacement in vocab:
        text = pattern.sub(replacement, text)
    return text


def _has_japanese(text: str) -> bool:
    """Retourne True si le texte contient du japonais/CJK traduisible par le modèle ja→en."""
    for ch in text:
        cp = ord(ch)
        if (0x3040 <= cp <= 0x30FA or   # hiragana + katakana (sans ・ U+30FB)
                0x30FC <= cp <= 0x30FF or   # katakana suite (ー ヾ ヿ)
                0xFF65 <= cp <= 0xFF9F or   # katakana demi-largeur
                0x4E00 <= cp <= 0x9FFF or   # CJK unifiés
                0x3400 <= cp <= 0x4DBF):    # CJK extension A
            return True
    return False


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def _load_model(model_dir: str):
    import sentencepiece as spm
    import ctranslate2

    ct2_dir = os.path.join(model_dir, "model")
    spm_path = os.path.join(model_dir, "sentencepiece.model")

    if not os.path.isdir(ct2_dir):
        sys.exit(f"Répertoire CT2 introuvable : {ct2_dir}")
    if not os.path.exists(spm_path):
        sys.exit(f"Tokenizer introuvable : {spm_path}")

    translator = ctranslate2.Translator(
        ct2_dir,
        device="cpu",
        compute_type="int8",
        inter_threads=1,
        intra_threads=_N_CORES,
    )
    sp = spm.SentencePieceProcessor()
    sp.load(spm_path)
    return translator, sp


def _translate_lines(
    lines: list[str],
    translator,
    sp,
    chunk_size: int,
    progress_offset: int,
    total_ops: int,
) -> list[str]:
    """Traduit une liste de lignes (non-vides) et émet des PROGRESS."""
    results = []
    done = 0
    n_chunks = (len(lines) + chunk_size - 1) // chunk_size

    for ci in range(n_chunks):
        chunk = lines[ci * chunk_size : (ci + 1) * chunk_size]
        encoded = [sp.encode(t, out_type=str) for t in chunk]
        _log(f"[chunk {ci+1}/{n_chunks}] {len(chunk)} seg…")
        t0 = time.monotonic()
        out = translator.translate_batch(
            encoded,
            beam_size=2,
            max_decoding_length=256,
            repetition_penalty=1.2,
            no_repeat_ngram_size=4,
        )
        dt = time.monotonic() - t0
        done += len(chunk)
        _log(f"PROGRESS:{progress_offset + done}/{total_ops}")
        _log(f"  {dt:.1f}s — {dt/len(chunk):.2f}s/seg")
        for r in out:
            results.append(_clean(sp.decode(r.hypotheses[0])))
        del out, encoded
        gc.collect()

    return results


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: opusmt_translate.py <model_dir1> [<model_dir2>]")

    model_dirs = sys.argv[1:]
    if len(model_dirs) > 2:
        model_dirs = model_dirs[:2]

    pivot = len(model_dirs) == 2
    mode = "pivot en" if pivot else "direct"
    _log(f"Mode : {mode} | cores={_N_CORES}")

    for d in model_dirs:
        if not os.path.isdir(d):
            sys.exit(f"Répertoire modèle introuvable : {d}")

    try:
        import sentencepiece  # noqa: F401
        import ctranslate2    # noqa: F401
    except ImportError as e:
        sys.exit(str(e))

    _log(f"Chargement modèle 1 : {os.path.basename(model_dirs[0])}…")
    tr1, sp1 = _load_model(model_dirs[0])

    tr2, sp2 = None, None
    if pivot:
        _log(f"Chargement modèle 2 : {os.path.basename(model_dirs[1])}…")
        tr2, sp2 = _load_model(model_dirs[1])

    # PA7 : chargement du vocabulaire domaine
    domain_vocab = _load_domain_vocab()

    _log("Lecture stdin…")
    try:
        texts = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"JSON invalide : {e}")
    _log(f"{len(texts)} segment(s) reçus")

    # Sépare les textes non-vides pour ne pas perdre les positions.
    # Passthrough : segments ASCII purs OU sans aucun caractère japonais/CJK.
    # Le modèle ja→en produit <unk> sur du texte sans japonais → résultat "? ? ?".
    non_empty = [(i, t.strip()) for i, t in enumerate(texts) if t.strip()]
    to_translate_items = [(i, t) for i, t in non_empty
                          if not all(ord(c) < 128 for c in t) and _has_japanese(t)]
    passthrough = {i: t for i, t in non_empty
                   if all(ord(c) < 128 for c in t) or not _has_japanese(t)}

    n_pass = len(passthrough)
    if n_pass:
        _log(f"{n_pass} segment(s) passthrough (ASCII ou sans contenu japonais)")

    # PA2 : expansion des blocs longs en sous-segments sur frontières de phrases
    expanded = []  # liste de (orig_i, sous_texte)
    for orig_i, t in to_translate_items:
        for part in _split_for_model(t):
            expanded.append((orig_i, part))
    n_extra = len(expanded) - len(to_translate_items)
    if n_extra > 0:
        _log(f"PA2: {n_extra} sous-segment(s) créé(s) par découpe de blocs longs")

    src_lines = [t for _, t in expanded]
    total_ops = len(src_lines) * (2 if pivot else 1)

    _log(f"{len(to_translate_items)} blocs ({len(src_lines)} sous-segments) "
         f"à traduire (total_ops={total_ops})…")

    # ── Étape 1 ───────────────────────────────────────────────────────────────
    step1 = _translate_lines(src_lines, tr1, sp1, _CHUNK_SIZE, 0, total_ops)

    # Libère le modèle 1 si on en a un deuxième (économise la RAM)
    if pivot:
        del tr1, sp1
        gc.collect()

    # ── Étape 2 (pivot) ───────────────────────────────────────────────────────
    if pivot:
        step2 = _translate_lines(step1, tr2, sp2, _CHUNK_SIZE, len(src_lines), total_ops)
        final_parts = step2
    else:
        final_parts = step1

    # PA7 : vocabulaire domaine sur chaque segment traduit
    if domain_vocab:
        final_parts = [_apply_domain_vocab(t, domain_vocab) for t in final_parts]

    # ── Reconstruction dans l'ordre original ──────────────────────────────────
    # Regroupe les sous-segments par indice original (PA2)
    parts_map = {}
    for (orig_i, _), translated in zip(expanded, final_parts):
        parts_map.setdefault(orig_i, []).append(translated)

    orig_src_map = {i: t for i, t in to_translate_items}

    output = list(texts)  # copie avec les vides conservés
    n_fallback = 0
    for orig_i, parts in parts_map.items():
        joined = ' '.join(p for p in parts if p.strip())
        src = orig_src_map[orig_i]
        # PA3 : quality gate — fallback sur le japonais si traduction ratée
        if _is_failed_translation(src, joined):
            output[orig_i] = src
            n_fallback += 1
        else:
            output[orig_i] = joined
    if n_fallback:
        _log(f"PA3: {n_fallback} segment(s) remplacé(s) par le texte source "
             f"(traduction ratée)")

    for orig_i, t in passthrough.items():
        output[orig_i] = t

    _log(f"Terminé ({len(output)} résultats) — écriture stdout…")
    json.dump(output, sys.stdout, ensure_ascii=False)
    _log("OK")


if __name__ == "__main__":
    main()
