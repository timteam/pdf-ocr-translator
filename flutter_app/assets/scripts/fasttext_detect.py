#!/usr/bin/env python3
"""Détection de langue via FastText LID.
Usage : python3 fasttext_detect.py <model_path>
stdin  → une ligne de texte
stdout → __label__xx (BCP-47 approximatif)
"""
import sys

if len(sys.argv) < 2:
    sys.exit("Usage: fasttext_detect.py <model_path>")

try:
    import fasttext
except ImportError:
    sys.exit("fasttext non installé. Installer : pip install fasttext-wheel")

model = fasttext.load_model(sys.argv[1])

for line in sys.stdin:
    line = line.strip()
    if line:
        labels, _ = model.predict(line)
        print(labels[0] if labels else "__label__en")
