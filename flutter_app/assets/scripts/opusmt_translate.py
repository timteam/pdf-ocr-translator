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


def translate_line(line, translator, src_sp, tgt_sp, lang_token=None):
    if not line.strip():
        return line
    tokens = src_sp.encode(line, out_type=str)
    if not tokens:
        return line
    # Préfixe le token de langue pour les modèles multilingues (ex: >>fra<<, >>jpn<<)
    if lang_token:
        tokens = [lang_token] + tokens
    result = translator.translate_batch(
        [tokens],
        beam_size=2,
        max_decoding_length=512,
        max_batch_size=1,
    )
    return tgt_sp.decode(result[0].hypotheses[0])


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: opusmt_translate.py <model_dir> [--token TOKEN]")

    model_dir = sys.argv[1]
    if not os.path.isdir(model_dir):
        sys.exit(f"Répertoire modèle introuvable : {model_dir}")

    # Lecture du token de langue optionnel
    lang_token = None
    if '--token' in sys.argv:
        idx = sys.argv.index('--token')
        if idx + 1 < len(sys.argv):
            lang_token = sys.argv[idx + 1]

    try:
        import ctranslate2
    except ImportError:
        sys.exit("ctranslate2 non installé (pip install ctranslate2)")

    def _log(msg):
        print(msg, file=sys.stderr, flush=True)

    _log(f"SPM source…")
    src_sp = load_sp(model_dir, "source.spm", "sentencepiece.bpe.model")
    _log(f"SPM target…")
    tgt_sp = load_sp(model_dir, "target.spm", "sentencepiece.bpe.model")

    if src_sp is None:
        sys.exit(f"Aucun modèle SentencePiece trouvé dans {model_dir}")
    if tgt_sp is None:
        tgt_sp = src_sp  # Certains modèles partagent le même SPM
    _log(f"SPM OK")

    _log(f"ctranslate2.Translator chargement…")
    translator = ctranslate2.Translator(
        model_dir,
        device="cpu",
        inter_threads=2,
        intra_threads=2,
    )
    _log(f"Modèle chargé")

    _log(f"Lecture stdin…")
    try:
        texts = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"Entrée JSON invalide : {e}")
    _log(f"{len(texts)} segment(s) reçus")

    results = []
    for i, text in enumerate(texts):
        if i % 20 == 0:
            _log(f"Traduction {i}/{len(texts)}…")
        if not text or not text.strip():
            results.append(text or "")
            continue
        lines = text.split("\n")
        translated_lines = [
            translate_line(line, translator, src_sp, tgt_sp, lang_token)
            for line in lines
        ]
        results.append("\n".join(translated_lines))

    _log(f"Traduction terminée ({len(results)} résultats) — écriture stdout…")
    json.dump(results, sys.stdout, ensure_ascii=False)
    _log(f"OK")


if __name__ == "__main__":
    main()
