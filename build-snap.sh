#!/bin/bash
# Snap Build Script for PDF OCR Translator
# Builds a Debian snap package for Linux distribution

set -e

echo "📦 Building PDF OCR Translator Snap Package"
echo "==========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if snapcraft is installed
if ! command -v snapcraft &> /dev/null; then
    echo -e "${RED}❌ Snapcraft is not installed!${NC}"
    echo -e "${YELLOW}Please install it with:${NC}"
    echo "sudo snap install snapcraft --classic"
    exit 1
fi

echo -e "${BLUE}✅ Snapcraft found: $(snapcraft --version)${NC}"

# Create build directory
BUILD_DIR="./snap-builds"
mkdir -p "$BUILD_DIR"

echo -e "${YELLOW}🔍 Téléchargement/vérification des wheels Python...${NC}"
# Toujours exécuter le script : il est idempotent (skip les fichiers déjà complets)
# et s'assure que toutes les dépendances transitives sont présentes.
./scripts/download_pip_wheels.sh

echo -e "${YELLOW}🔨 Building Flutter Linux bundle...${NC}"
echo "This may take several minutes..."

# Ensure host OS is Linux for desktop build
if [[ "$(uname -s)" != "Linux" ]]; then
  echo -e "${RED}❌ Snap build requires a Linux host.${NC}"
  echo -e "${YELLOW}Please run this script on Linux, or build the Linux bundle on a Linux machine.${NC}"
  exit 1
fi

# Build Flutter Linux bundle if necessary
if ! command -v flutter &> /dev/null; then
    echo -e "${RED}❌ Flutter CLI is not installed!${NC}"
    echo -e "${YELLOW}Please install Flutter and ensure it is on your PATH.${NC}"
    echo "https://docs.flutter.dev/get-started/install"
    exit 1
fi

# Verify Linux build toolchain
for tool in cmake ninja clang++ pkg-config; do
  if ! command -v "$tool" &> /dev/null; then
    echo -e "${RED}❌ Required build tool missing: $tool${NC}"
    echo -e "${YELLOW}Install Linux desktop build dependencies before continuing.${NC}"
    echo "Example (Debian/Ubuntu):"
    echo "  sudo apt update && sudo apt install build-essential cmake ninja-build clang++ pkg-config libgtk-3-dev"
    exit 1
  fi
done

cd flutter_app

if [[ ! -d linux ]]; then
  echo -e "${YELLOW}ℹ️  Linux desktop support is not configured. Generating linux desktop files...${NC}"
  flutter create --platforms=linux .
fi

flutter clean
flutter pub get
flutter build linux --release
cd ..

echo -e "${YELLOW}🔨 Packaging snap from built bundle...${NC}"

# Mode managé (LXD/Multipass) : snapcraft crée un container Ubuntu 24.04 et le
# réutilise entre les builds — les packages apt sont cachés dans ce container.
echo "This may take several minutes (plus long on first run while container is created)..."

# Build the snap
if snapcraft pack; then
    echo -e "${GREEN}✅ Snap build completed successfully!${NC}"

    # List generated files
    echo ""
    echo -e "${BLUE}📦 Generated snap files:${NC}"
    ls -la *.snap 2>/dev/null || echo "No .snap files found in current directory"

    # Move snap to build directory if it exists
    if ls *.snap 1> /dev/null 2>&1; then
        mv *.snap "$BUILD_DIR/" 2>/dev/null || true
        echo ""
        echo -e "${GREEN}📁 Snap moved to: $BUILD_DIR${NC}"
        ls -la "$BUILD_DIR/"
    fi

    echo ""
    echo -e "${GREEN}🎉 Snap package ready for distribution!${NC}"
    echo ""
    echo -e "${BLUE}📋 Installation instructions:${NC}"
    echo "sudo snap install $BUILD_DIR/*.snap --dangerous"
    echo ""
    echo -e "${BLUE}📋 Publishing to Snap Store:${NC}"
    echo "snapcraft login"
    echo "snapcraft upload $BUILD_DIR/*.snap"

else
    echo -e "${RED}❌ Snap build failed!${NC}"
    echo -e "${YELLOW}Check the error messages above for details.${NC}"
    exit 1
fi