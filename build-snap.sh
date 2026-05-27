#!/bin/bash
# Snap Build Script for PDF OCR Translator
#
# Usage:
#   ./build-snap.sh           — build incrémental (rapide, recommandé)
#   ./build-snap.sh --clean   — rebuild complet depuis zéro (lent, ~15 min)
#                               Obligatoire après modification de stage-packages

set -e

CLEAN=false
for arg in "$@"; do
  [[ "$arg" == "--clean" ]] && CLEAN=true
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "📦 Building PDF OCR Translator Snap Package"
echo "==========================================="
$CLEAN && echo -e "${YELLOW}Mode : rebuild complet (--clean)${NC}" \
       || echo -e "${BLUE}Mode : build incrémental${NC}"

if ! command -v snapcraft &> /dev/null; then
    echo -e "${RED}❌ Snapcraft is not installed!${NC}"
    echo "sudo snap install snapcraft --classic"
    exit 1
fi
echo -e "${BLUE}✅ Snapcraft found: $(snapcraft --version)${NC}"

BUILD_DIR="./snap-builds"
mkdir -p "$BUILD_DIR"

# ── Modèle FastText LID (asset Flutter, ~917 KB) ─────────────────────────────
echo -e "${YELLOW}🔍 Vérification du modèle FastText LID...${NC}"
./scripts/download_fasttext_model.sh

# ── Wheels Python ────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔍 Vérification des wheels Python...${NC}"
./scripts/download_pip_wheels.sh

# ── Flutter build (conditionnel) ─────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
  echo -e "${RED}❌ Snap build requires a Linux host.${NC}"
  exit 1
fi

if ! command -v flutter &> /dev/null; then
    echo -e "${RED}❌ Flutter CLI is not installed!${NC}"
    exit 1
fi

for tool in cmake ninja clang++ pkg-config; do
  if ! command -v "$tool" &> /dev/null; then
    echo -e "${RED}❌ Required build tool missing: $tool${NC}"
    echo "  sudo apt install build-essential cmake ninja-build clang++ pkg-config libgtk-3-dev"
    exit 1
  fi
done

cd flutter_app

if [[ ! -d linux ]]; then
  flutter create --platforms=linux .
fi

BUNDLE="build/linux/x64/release/bundle/pdf_ocr_translator"

# Rebuild Flutter seulement si des sources Dart/pubspec ont changé depuis
# le dernier binaire — évite 3-5 min inutiles à chaque build snap.
NEEDS_FLUTTER_BUILD=false
if [[ ! -f "$BUNDLE" ]]; then
  NEEDS_FLUTTER_BUILD=true
elif find lib pubspec.yaml -newer "$BUNDLE" -print -quit 2>/dev/null | grep -q .; then
  NEEDS_FLUTTER_BUILD=true
fi

if $NEEDS_FLUTTER_BUILD; then
  echo -e "${YELLOW}🔨 Flutter sources modifiées — rebuild...${NC}"
  flutter pub get
  flutter build linux --release
else
  echo -e "${GREEN}⚡ Flutter bundle à jour — rebuild ignoré${NC}"
fi

cd ..

# ── Snapcraft ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔨 Packaging snap...${NC}"

# --clean : nettoie tout le state snapcraft (parts/stage/prime).
# Nécessaire après modification de stage-packages pour éviter un prime
# incohérent. En build incrémental, snapcraft détecte les changements seul.
if $CLEAN; then
  echo "Nettoyage du state snapcraft..."
  snapcraft clean
fi

# Hash de snapcraft.yaml pour détecter automatiquement un changement de
# stage-packages et avertir l'utilisateur s'il n'a pas passé --clean.
HASH_FILE=".snapcraft_yaml_hash"
CURRENT_HASH=$(sha256sum snapcraft.yaml | cut -d' ' -f1)
if [[ -f "$HASH_FILE" ]]; then
  PREV_HASH=$(cat "$HASH_FILE")
  if [[ "$CURRENT_HASH" != "$PREV_HASH" ]] && ! $CLEAN; then
    echo -e "${YELLOW}⚠️  snapcraft.yaml a changé depuis le dernier build.${NC}"
    echo -e "${YELLOW}   Si tu as modifié des stage-packages, relance avec --clean.${NC}"
  fi
fi

if snapcraft pack; then
    echo "$CURRENT_HASH" > "$HASH_FILE"
    echo -e "${GREEN}✅ Snap build completed successfully!${NC}"

    if ls *.snap 1> /dev/null 2>&1; then
        mv *.snap "$BUILD_DIR/" 2>/dev/null || true
        echo -e "${GREEN}📁 Snap moved to: $BUILD_DIR${NC}"
        ls -la "$BUILD_DIR/"
    fi

    echo ""
    echo -e "${GREEN}🎉 Snap package ready!${NC}"
    echo -e "${BLUE}Installation :${NC} sudo snap install $BUILD_DIR/*.snap --dangerous"
    echo -e "${BLUE}Connexion    :${NC} sudo snap connect pdf-ocr-translator:gnome-46-2404 gnome-46-2404:gnome-46-2404"
else
    echo -e "${RED}❌ Snap build failed!${NC}"
    exit 1
fi
