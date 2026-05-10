#!/bin/bash
# Quick test script for PDF OCR Translator snap

set -e

echo "🧪 Testing PDF OCR Translator Snap"
echo "==================================="

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if snap is installed
if ! snap list | grep -q pdf-ocr-translator; then
    echo -e "${RED}❌ PDF OCR Translator snap is not installed${NC}"
    echo -e "${YELLOW}Install it first: sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Snap is installed${NC}"

# Test basic functionality
echo -e "${YELLOW}🔍 Testing snap info...${NC}"
snap info pdf-ocr-translator

echo ""
echo -e "${YELLOW}🔍 Testing snap connections...${NC}"
snap connections pdf-ocr-translator

echo ""
echo -e "${GREEN}✅ Snap test completed!${NC}"
echo ""
echo -e "${BLUE}📋 Manual testing:${NC}"
echo "1. Run: pdf-ocr-translator"
echo "2. Try selecting a PDF file"
echo "3. Test OCR and translation features"
echo "4. Verify offline functionality"