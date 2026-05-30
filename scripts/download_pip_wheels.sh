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

# Le pip système de Python 3.14 (≤ 25.1.1) a un bug de parsing JSON avec l'index
# PyPI (PEP 691) : JSONDecodeError sur les réponses de l'index simple.
# Correction : utiliser pip.pyz (bootstrap auto-contenu, pip ≥ 26.1.1).
PIP_PYZ=$(mktemp /tmp/pip_XXXXXX.pyz)
trap 'rm -f "$PIP_PYZ"' EXIT

if command -v curl &>/dev/null; then
  echo "→ Téléchargement de pip bootstrap (pip.pyz)..."
  curl -fL --progress-bar "https://bootstrap.pypa.io/pip/pip.pyz" -o "$PIP_PYZ"
elif command -v wget &>/dev/null; then
  echo "→ Téléchargement de pip bootstrap (pip.pyz)..."
  wget --show-progress -q "https://bootstrap.pypa.io/pip/pip.pyz" -O "$PIP_PYZ"
else
  echo "❌ curl ou wget requis pour télécharger pip bootstrap."
  exit 1
fi

if ! python3 "$PIP_PYZ" --version &>/dev/null; then
  echo "❌ Impossible d'utiliser pip.pyz avec python3."
  exit 1
fi

PIP="python3 $PIP_PYZ"

echo "⬇️  Téléchargement des wheels Python pour le snap..."
echo "   Plateforme cible : linux x86_64 / Python 3.12 (core24)"
echo "   Destination      : $WHEELS_DIR"
echo "   pip              : $($PIP --version)"
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
