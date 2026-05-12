#!/usr/bin/env bash
# Downloads tessdata_best models for all languages supported by the app.
# Run once before building: ./scripts/setup_tessdata_best.sh
#
# Files land in tessdata/ at the project root (gitignored).
# The flutter build picks them up via CMakeLists.txt and places them
# next to the binary as tessdata/, where ocr_service.dart finds them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TESSDATA_DIR="$PROJECT_DIR/tessdata"

BASE_URL="https://github.com/tesseract-ocr/tessdata_best/raw/main"

LANGS=(
  eng fra spa deu ita por nld pol
  rus jpn jpn_vert chi_sim kor ara hin tha vie
)

mkdir -p "$TESSDATA_DIR"
echo "Target directory: $TESSDATA_DIR"
echo ""

for lang in "${LANGS[@]}"; do
  FILE="$TESSDATA_DIR/${lang}.traineddata"
  if [[ -f "$FILE" ]]; then
    echo "  [skip] ${lang}.traineddata (already downloaded)"
    continue
  fi
  echo "  Downloading ${lang}.traineddata ..."
  wget -q --show-progress -O "$FILE" "$BASE_URL/${lang}.traineddata"
done

# Tesseract needs its configs/ and tessconfigs/ subdirectories in TESSDATA_PREFIX
# to produce TSV output (read_params_file looks for configs/tsv there).
echo ""
echo "Copying Tesseract config files..."
SYSTEM_TESSDATA="/usr/share/tesseract-ocr/5/tessdata"
for subdir in configs tessconfigs; do
  if [[ -d "$SYSTEM_TESSDATA/$subdir" ]]; then
    cp -r "$SYSTEM_TESSDATA/$subdir" "$TESSDATA_DIR/"
    echo "  Copied $subdir/ from system tesseract"
  else
    echo "  [warn] $SYSTEM_TESSDATA/$subdir not found — install tesseract-ocr first"
  fi
done

echo ""
echo "All models ready. Next steps:"
echo "  flutter build linux   → tessdata/ bundled next to the binary"
echo "  ./build-snap.sh       → tessdata/ included in the snap package"
