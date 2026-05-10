#!/bin/bash
# Mobile App Build Script
# Builds native APKs and IPAs for app store deployment

set -e

echo "🚀 Building PDF OCR Translator Mobile Apps"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create build directory
BUILD_DIR="./builds"
mkdir -p "$BUILD_DIR"

cd flutter_app

echo -e "${YELLOW}📱 Building Android APK...${NC}"

# Build Android APK
flutter build apk --release --split-per-abi

# Copy APKs to build directory
cp build/app/outputs/flutter-apk/app-release.apk "$BUILD_DIR/pdf-ocr-translator.apk"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$BUILD_DIR/pdf-ocr-translator-arm64.apk" 2>/dev/null || true

echo -e "${GREEN}✅ Android APK built: $BUILD_DIR/pdf-ocr-translator.apk${NC}"

echo -e "${YELLOW}🍎 Building iOS IPA...${NC}"

# Build iOS (requires macOS with Xcode)
if [[ "$OSTYPE" == "darwin"* ]]; then
    flutter build ios --release --no-codesign
    # Copy IPA to build directory (would need proper signing for App Store)
    echo -e "${GREEN}✅ iOS build completed (needs signing for App Store)${NC}"
else
    echo -e "${RED}⚠️  iOS build requires macOS with Xcode${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Build completed!${NC}"
echo ""
echo "📦 Generated files:"
ls -la "$BUILD_DIR/"
echo ""
echo "📋 Next steps for deployment:"
echo "  Android: Sign APK and upload to Google Play Console"
echo "  iOS: Sign IPA and upload to App Store Connect"
echo ""
echo "🔐 Signing requirements:"
echo "  Android: Use jarsigner or apksigner with your keystore"
echo "  iOS: Use Xcode or fastlane for code signing"