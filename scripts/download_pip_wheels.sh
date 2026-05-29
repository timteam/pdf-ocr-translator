#!/bin/bash
# Télécharge les wheels pip requis pour le build snap.
# Compatible macOS et Linux. Télécharge toujours des wheels Linux x86_64 (cp312)
# pour être utilisables dans le container LXC snapcraft (core26 = Python 3.12).
# À exécuter une fois avant build-snap.sh ; les wheels sont réutilisés entre builds.
#
# Intégrité : pip vérifie automatiquement les SHA256 depuis l'index PyPI.
#
# Stack OCR : rapidocr-onnxruntime + onnxruntime (compatible AVX, sans AVX2)
# Stack traduction : ctranslate2 + sentencepiece + fasttext-wheel
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHEELS_DIR="$SCRIPT_DIR/../wheels"
mkdir -p "$WHEELS_DIR"

PIP="python3 -m pip"

if ! python3 -m pip --version &>/dev/null; then
  echo "❌ python3 -m pip non disponible."
  echo "   macOS : brew install python  ou  python3 -m ensurepip"
  echo "   Linux : sudo apt install python3-pip"
  exit 1
fi

echo "⬇️  Téléchargement des wheels Python pour le snap..."
echo "   Plateforme cible : linux x86_64 / Python 3.12 (core24)"
echo "   Destination      : $WHEELS_DIR"
echo ""

# ---------------------------------------------------------------------------
# rapidocr-onnxruntime : OCR PaddleOCR via ONNX Runtime (AVX, sans AVX2)
# onnxruntime          : moteur ONNX — wheel manylinux_2_27 pour cp312
# opencv-python        : traitement image pour rapidocr
# ctranslate2          : runtime Opus-MT (traduction offline)
# sentencepiece        : tokenizer Opus-MT
# fasttext-wheel       : détection de langue FastText LID (176 langues)
#
# onnxruntime nécessite manylinux_2_27 (glibc 2.27+) — core24 = Ubuntu 24.04
# qui fournit glibc 2.39, compatible.
# ---------------------------------------------------------------------------
echo "→ Téléchargement des wheels..."
$PIP download \
  --no-cache-dir \
  --only-binary :all: \
  --find-links "$WHEELS_DIR" \
  --platform manylinux_2_27_x86_64 \
  --platform manylinux_2_28_x86_64 \
  --platform manylinux2014_x86_64 \
  --platform manylinux_2_17_x86_64 \
  --python-version 312 \
  --implementation cp \
  --abi cp312 \
  --dest "$WHEELS_DIR" \
  rapidocr-onnxruntime \
  onnxruntime \
  opencv-python \
  ctranslate2 \
  sentencepiece \
  fasttext-wheel

echo ""
echo "✅ Wheels téléchargés :"
ls -lh "$WHEELS_DIR/"*.whl 2>/dev/null | awk '{print "   " $5 "\t" $9}' || true
echo ""
echo "Total : $(du -sh "$WHEELS_DIR/" | cut -f1)"
