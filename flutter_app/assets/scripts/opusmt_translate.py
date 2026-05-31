#!/usr/bin/env python3
"""
Traduit un tableau JSON de textes avec un modèle CTranslate2 opus-mt.

Usage : python3 opusmt_translate.py <model_dir> [--token >>fr<<]
  --token TOKEN   Token de langue initial à préfixer aux tokens source
                  (requis par les modèles multilingues : >>fr<<, >>jpn<<, etc.)
  stdin  : tableau JSON de chaînes  →  ["texte1", "texte2", …]
  stdout : tableau JSON des traductions (même longueur et ordre)
  stderr : messages de diagnostic
"""
import sys
import os

# 4 threads pour ctranslate2 + ses libs internes (MKL/Eigen/OpenMP).
# Doit être positionné avant tout import de numpy/ctranslate2.
_N_THREADS = "4"
os.environ.setdefault("OMP_NUM_THREADS",         _N_THREADS)
os.environ.setdefault("MKL_NUM_THREADS",         _N_THREADS)
os.environ.setdefault("OPENBLAS_NUM_THREADS",    _N_THREADS)

import json


def load_sp(model_dir, *names):
    try:
        import sentencepiece as spm
    except ImportError:
        sys.exit("sentencepiece non installé (pip install sentencepiece)")
    for name in names:
        path = os.path.join(model_dir, name)
        if os.path.exists(path):
            sp = spm.SentencePieceProcessor()
            sp.load(path)
            return sp
    return None


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: opusmt_translate.py <model_dir> [--token TOKEN]")

    model_dir = sys.argv[1]
    if not os.path.isdir(model_dir):
        sys.exit(f"Répertoire modèle introuvable : {model_dir}")

    lang_token = None
    if "--token" in sys.argv:
        idx = sys.argv.index("--token")
        if idx + 1 < len(sys.argv):
            lang_token = sys.argv[idx + 1]

    try:
        import ctranslate2
    except ImportError:
        sys.exit("ctranslate2 non installé (pip install ctranslate2)")

    _log("SPM source…")
    src_sp = load_sp(model_dir, "source.spm", "sentencepiece.bpe.model")
    _log("SPM target…")
    tgt_sp = load_sp(model_dir, "target.spm", "sentencepiece.bpe.model")

    if src_sp is None:
        sys.exit(f"Aucun modèle SentencePiece trouvé dans {model_dir}")
    if tgt_sp is None:
        tgt_sp = src_sp

    _log("ctranslate2.Translator chargement…")
    translator = ctranslate2.Translator(
        model_dir,
        device="cpu",
        inter_threads=1,
        intra_threads=int(_N_THREADS),
    )
    _log("Modèle chargé")

    _log("Lecture stdin…")
    try:
        texts = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"Entrée JSON invalide : {e}")
    _log(f"{len(texts)} segment(s) reçus")

    # Les modèles opus-mt ont des positional encodings jusqu'à la position 511.
    # Tout dépassement produit RuntimeError. On tronque en amont.
    _MAX_TOKENS = 512

    # ── Encodage : décompose chaque texte en lignes, encode chaque ligne ──────
    # Structure : pour chaque texte, liste de (ligne_originale, tokens|None)
    struct = []
    for text in texts:
        lines = text.split("\n") if text else [""]
        line_tokens = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                line_tokens.append((line, None))
                continue
            tokens = src_sp.encode(line, out_type=str)
            if not tokens:
                line_tokens.append((line, None))
                continue
            if lang_token:
                tokens = tokens[: _MAX_TOKENS - 1]  # réserve 1 position pour le token de langue
                tokens = [lang_token] + tokens
            else:
                tokens = tokens[: _MAX_TOKENS]
            line_tokens.append((line, tokens))
        struct.append(line_tokens)

    # ── Collecte de toutes les lignes à traduire (batch unique) ───────────────
    flat = []  # (text_idx, line_idx, tokens)
    for ti, line_tokens in enumerate(struct):
        for li, (_, tokens) in enumerate(line_tokens):
            if tokens is not None:
                flat.append((ti, li, tokens))

    _log(f"Batch : {len(flat)} ligne(s) à traduire…")

    translated: dict[tuple[int, int], str] = {}

    if flat:
        tokens_batch = [t for _, _, t in flat]
        _log("translate_batch — début…")
        results = translator.translate_batch(
            tokens_batch,
            beam_size=2,
            max_decoding_length=512,
        )
        _log("translate_batch — terminé")
        for (ti, li, _), result in zip(flat, results):
            translated[(ti, li)] = tgt_sp.decode(result.hypotheses[0])

    # ── Reconstruction des textes originaux ───────────────────────────────────
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
