#!/usr/bin/env python3
"""
Convertit un répertoire de modèle HuggingFace (PyTorch) en CTranslate2 INT8.

Usage:
  python3 convert_model.py <source_dir> <output_dir>

  source_dir : répertoire contenant les fichiers PyTorch téléchargés
               (config.json + pytorch_model.bin ou model.safetensors + *.spm)
  output_dir : répertoire de sortie (model.bin, shared_vocabulary.json, *.spm)
"""
import sys
import os
import glob
import shutil

_WEIGHT_FILES = ("model.safetensors", "pytorch_model.bin", "model.pt")


def main():
    if len(sys.argv) < 3:
        sys.exit("Usage: convert_model.py <source_dir> <output_dir>")

    src, dst = sys.argv[1], sys.argv[2]

    if not os.path.isdir(src):
        sys.exit(f"Source introuvable : {src}")

    if not any(os.path.exists(os.path.join(src, f)) for f in _WEIGHT_FILES):
        sys.exit(
            f"Aucun fichier de poids dans {src}\n"
            f"  Attendu : {', '.join(_WEIGHT_FILES)}"
        )

    try:
        import ctranslate2
    except ImportError:
        sys.exit("ctranslate2 non disponible (PYTHONPATH incorrect?)")

    os.makedirs(dst, exist_ok=True)

    print("  Conversion CTranslate2 INT8…", flush=True)
    if os.path.exists(os.path.join(src, "decoder.yml")):
        converter = ctranslate2.converters.OpusMTConverter(src)
    elif hasattr(ctranslate2.converters, "TransformersConverter"):
        converter = ctranslate2.converters.TransformersConverter(
            src, low_cpu_mem_usage=True
        )
    else:
        available = sorted(
            x for x in dir(ctranslate2.converters)
            if "Converter" in x and not x.startswith("_")
        )
        sys.exit(f"TransformersConverter introuvable. Disponibles : {available}")

    converter.convert(dst, quantization="int8", force=True)
    print("  model.bin + shared_vocabulary.json ✓", flush=True)

    copied = []
    for pattern in ("*.spm", "*.model"):
        for f in glob.glob(os.path.join(src, pattern)):
            dst_file = os.path.join(dst, os.path.basename(f))
            if not os.path.exists(dst_file):
                shutil.copy(f, dst_file)
                copied.append(os.path.basename(f))
    if copied:
        print(f"  SPM : {', '.join(copied)}", flush=True)

    if not os.path.exists(os.path.join(dst, "model.bin")):
        sys.exit(f"Échec : model.bin absent dans {dst}")

    size_mb = sum(
        os.path.getsize(os.path.join(dst, f))
        for f in os.listdir(dst)
        if not f.startswith(".")
    ) / 1024 / 1024
    print(f"  ✓ {dst} ({size_mb:.0f} MB)", flush=True)


if __name__ == "__main__":
    main()
