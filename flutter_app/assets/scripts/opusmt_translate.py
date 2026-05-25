#!/usr/bin/env python3
"""
Traduit un tableau JSON de textes avec un modèle CTranslate2 opus-mt-tc-tiny.

Usage : python3 opusmt_translate.py <model_dir>
  stdin  : tableau JSON de chaînes  →  ["texte1", "texte2", …]
  stdout : tableau JSON des traductions (même longueur et ordre)
  stderr : messages de diagnostic
"""
import sys
import os
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


def translate_line(line, translator, src_sp, tgt_sp):
    if not line.strip():
        return line
    tokens = src_sp.encode(line, out_type=str)
    if not tokens:
        return line
    result = translator.translate_batch(
        [tokens],
        beam_size=2,
        max_decoding_length=512,
        max_batch_size=1,
    )
    return tgt_sp.decode(result[0].hypotheses[0])


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: opusmt_translate.py <model_dir>")

    model_dir = sys.argv[1]
    if not os.path.isdir(model_dir):
        sys.exit(f"Répertoire modèle introuvable : {model_dir}")

    try:
        import ctranslate2
    except ImportError:
        sys.exit("ctranslate2 non installé (pip install ctranslate2)")

    src_sp = load_sp(model_dir, "source.spm", "sentencepiece.bpe.model")
    tgt_sp = load_sp(model_dir, "target.spm", "sentencepiece.bpe.model")

    if src_sp is None:
        sys.exit(f"Aucun modèle SentencePiece trouvé dans {model_dir}")

    translator = ctranslate2.Translator(
        model_dir,
        device="cpu",
        inter_threads=2,
        intra_threads=2,
    )

    try:
        texts = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"Entrée JSON invalide : {e}")

    results = []
    for text in texts:
        if not text or not text.strip():
            results.append(text or "")
            continue
        # Traduire ligne par ligne pour préserver les sauts de ligne internes
        lines = text.split("\n")
        translated_lines = [
            translate_line(line, translator, src_sp, tgt_sp)
            for line in lines
        ]
        results.append("\n".join(translated_lines))

    json.dump(results, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
