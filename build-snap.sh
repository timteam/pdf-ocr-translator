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

echo -e "${YELLOW}🔨 Building snap package...${NC}"
echo "This may take several minutes..."

# Build the snap
if snapcraft; then
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