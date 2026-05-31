#!/usr/bin/env python3
"""
Traduit un tableau JSON de textes avec NLLB-200-distilled-600M (CTranslate2).

Usage : python3 nllb_translate.py <model_dir> <src_lang> <tgt_lang>
  model_dir : répertoire CTranslate2 NLLB (model.bin + sentencepiece.bpe.model)
  src_lang  : code NLLB source  ex: jpn_Jpan  fra_Latn  eng_Latn
  tgt_lang  : code NLLB cible   ex: fra_Latn  eng_Latn  deu_Latn
  stdin     : tableau JSON de chaînes  →  ["texte1", "texte2", …]
  stdout    : tableau JSON des traductions (même longueur et ordre)
  stderr    : messages de diagnostic
"""
import sys
import os

# Doit être positionné avant tout import de numpy/ctranslate2.
_N_THREADS = "4"
os.environ.setdefault("OMP_NUM_THREADS",      _N_THREADS)
os.environ.setdefault("MKL_NUM_THREADS",      _N_THREADS)
os.environ.setdefault("OPENBLAS_NUM_THREADS", _N_THREADS)

import json


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    if len(sys.argv) < 4:
        sys.exit("Usage: nllb_translate.py <model_dir> <src_lang> <tgt_lang>")

    model_dir, src_lang, tgt_lang = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isdir(model_dir):
        sys.exit(f"Répertoire modèle introuvable : {model_dir}")

    try:
        import sentencepiece as spm
    except ImportError:
        sys.exit("sentencepiece non installé (pip install sentencepiece)")

    try:
        import ctranslate2
    except ImportError:
        sys.exit("ctranslate2 non installé (pip install ctranslate2)")

    spm_path = os.path.join(model_dir, "sentencepiece.bpe.model")
    if not os.path.exists(spm_path):
        sys.exit(f"Tokenizer introuvable : {spm_path}")

    _log("SPM chargement…")
    sp = spm.SentencePieceProcessor()
    sp.load(spm_path)

    _log("ctranslate2.Translator chargement…")
    translator = ctranslate2.Translator(
        model_dir,
        device="cpu",
        inter_threads=1,
        intra_threads=int(_N_THREADS),
    )
    _log(f"Modèle chargé ({src_lang} → {tgt_lang})")

    _log("Lecture stdin…")
    try:
        texts = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"Entrée JSON invalide : {e}")
    _log(f"{len(texts)} segment(s) reçus")

    # NLLB : encodage max 512 positions ; on réserve 1 pour le token de langue source.
    _MAX_TOKENS = 511

    # ── Encodage : décompose chaque texte en lignes ───────────────────────────
    struct = []
    for text in texts:
        lines = text.split("\n") if text else [""]
        line_tokens = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                line_tokens.append((line, None))
                continue
            tokens = sp.encode(stripped, out_type=str)
            if not tokens:
                line_tokens.append((line, None))
                continue
            # Préfixe langue source + troncature
            tokens = [src_lang] + tokens[:_MAX_TOKENS]
            line_tokens.append((line, tokens))
        struct.append(line_tokens)

    # ── Collecte du batch unique ──────────────────────────────────────────────
    flat = []
    for ti, line_tokens in enumerate(struct):
        for li, (_, tokens) in enumerate(line_tokens):
            if tokens is not None:
                flat.append((ti, li, tokens))

    _log(f"Batch : {len(flat)} ligne(s) à traduire…")
    translated: dict[tuple[int, int], str] = {}

    if flat:
        tokens_batch = [t for _, _, t in flat]
        # NLLB nécessite target_prefix pour forcer le token de langue cible en sortie.
        target_prefix = [[tgt_lang]] * len(tokens_batch)
        _log("translate_batch — début…")
        results = translator.translate_batch(
            tokens_batch,
            target_prefix=target_prefix,
            beam_size=2,
            max_decoding_length=512,
        )
        _log("translate_batch — terminé")
        for (ti, li, _), result in zip(flat, results):
            # Le premier token de sortie est le tgt_lang (token de contrôle) → ignorer.
            output_tokens = result.hypotheses[0][1:]
            translated[(ti, li)] = sp.decode(output_tokens)

    # ── Reconstruction ────────────────────────────────────────────────────────
    output = []
    for ti, line_tokens in enumerate(struct):
        parts = []
        for li, (orig_line, tokens) in enumerate(line_tokens):
            if tokens is None:
                parts.append(orig_line)
            else:
                parts.append(translated.get((ti, li), orig_line))
        output.append("\n".join(parts))

    _log(f"Traduction terminée ({len(output)} résultats) — écriture stdout…")
    json.dump(output, sys.stdout, ensure_ascii=False)
    _log("OK")


if __name__ == "__main__":
    main()
