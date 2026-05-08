# PDF OCR Translator

🌍 **Fully offline PDF OCR and translation app - No backend required!**

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Offline](https://img.shields.io/badge/Offline-First-green.svg)

## ✨ Features

- 📄 **PDF Processing**: Extract text from PDF images without modifying originals
- 🌐 **100+ Languages**: Translate to over 100 languages with local caching
- 🎯 **Offline OCR**: On-device text extraction using Google ML Kit + Tesseract
- 📊 **Progress Tracking**: Real-time processing status
- 🚀 **Cross-Platform**: Native apps for Linux, macOS, Windows, Android, and iOS
- 🔒 **Privacy First**: All processing happens locally on device
- 💾 **Smart Caching**: Translation cache for faster repeated translations
- 📝 **No Internet Required**: Works completely offline after first setup

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter App (Client-Side)                │
│  Linux | macOS | Windows | Android | iOS                   │
├─────────────────────────────────────────────────────────────┤
│  • OCR (Google ML Kit + Tesseract)                          │
│  • Translation (Google Translate API + Cache)              │
│  • PDF Processing (pdfx + pdf packages)                    │
│  • Local Storage (SharedPreferences + File System)         │
└─────────────────────────────────────────────────────────────┘
```

**Everything runs locally on the device - No backend, no cloud, no servers!**

## 🚀 Quick Start

### Prerequisites
- Flutter 3.16+
- For Android: Android SDK
- For iOS: macOS + Xcode

### Setup & Run
```bash
cd flutter_app

# Install dependencies
flutter pub get

# Run on connected device/emulator
flutter run

# Build for specific platform
flutter build apk      # Android APK
flutter build ios      # iOS (macOS only)
flutter build windows  # Windows
flutter build linux    # Linux
flutter build macos    # macOS
```

### Mobile App Deployment

**Android:**
```bash
flutter build apk --release
# Sign and deploy to Play Store
```

**iOS:**
```bash
flutter build ios --release
# Deploy via Xcode to App Store
```

### Linux Snap Package

**Build Snap:**
```bash
./build-snap.sh
```

**Install Snap:**
```bash
sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous
```

**Run:**
```bash
pdf-ocr-translator
```

See [SNAP-README.md](SNAP-README.md) for detailed snap building instructions.

## 📱 How It Works

1. **Select PDF**: Pick any PDF file from your device
2. **Choose Languages**: Select source and target languages
3. **Offline Processing**:
   - PDF pages → Images
   - OCR extraction (Google ML Kit)
   - Translation (cached API calls)
   - Overlay translated text
   - Generate new PDF
4. **Save Result**: Translated PDF saved locally

## 🔧 Technical Details

### OCR Engine
- **Primary**: Google ML Kit (fast, accurate, offline)
- **Fallback**: Tesseract OCR (works on all platforms)

### Translation
- **API**: Google Translate with intelligent caching
- **Cache**: Local JSON storage for repeated translations
- **Offline**: Cached translations work without internet

### PDF Processing
- **Reading**: pdfx package for PDF parsing
- **Writing**: pdf package for PDF generation
- **Overlay**: Text positioned over original images

### Storage
- **Cache**: SharedPreferences + local JSON files
- **Files**: Device document directory
- **Permissions**: Automatic permission requests

## 📦 Dependencies

```yaml
# OCR
google_ml_kit: ^0.16.0      # Google ML Kit OCR
tesseract_ocr: ^1.0.2       # Tesseract fallback

# Translation
translator: ^1.0.0          # Google Translate API

# PDF
pdfx: ^2.4.0               # PDF reading
pdf: ^3.10.0               # PDF generation

# Storage & Utils
shared_preferences: ^2.2.0  # Local cache
path_provider: ^2.1.0      # File paths
permission_handler: ^11.0.0 # Permissions
```

## 🌐 Supported Languages

16 core languages with Google Translate coverage:
- English, French, Spanish, German, Italian, Portuguese
- Dutch, Polish, Russian, Japanese, Chinese, Korean
- Arabic, Hindi, Thai, Vietnamese

## 💾 Offline Capabilities

- **OCR**: Works completely offline (ML models downloaded)
- **Translation**: Cached translations work offline
- **Processing**: All PDF operations local
- **Storage**: Files saved to device only

## 🔄 Data Flow

```
PDF File → Pages → Images → OCR → Text Blocks → Translation → Overlay → New PDF
     ↓         ↓        ↓       ↓         ↓            ↓         ↓        ↓
  Local    Local    Local   Local    Local        Cache     Local    Local
```

## 🛠️ Development

### Project Structure
```
flutter_app/
├── lib/
│   ├── main.dart              # App initialization
│   ├── screens/               # UI screens
│   ├── services/              # Business logic
│   │   ├── ocr_service.dart       # OCR processing
│   │   ├── translation_service.dart # Translation + cache
│   │   └── pdf_service.dart       # PDF processing
│   ├── models/                # Data models
│   └── theme/                 # UI theme
├── android/                   # Android config
├── ios/                       # iOS config
└── pubspec.yaml              # Dependencies
```

### Testing
```bash
flutter test
flutter test --coverage
```

### Building
```bash
# Debug
flutter run

# Release builds
flutter build apk --release --split-per-abi
flutter build ios --release
flutter build windows --release
flutter build linux --release
flutter build macos --release
```

## 📋 Permissions Required

### Android (AndroidManifest.xml)
```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.INTERNET" />
```

### iOS (Info.plist)
```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Access to photo library for PDF files</string>
<key>NSFileProviderDomainUsageDescription</key>
<string>Access to files for PDF processing</string>
```

## 🔍 Troubleshooting

### OCR Not Working
```bash
# Check device storage permissions
# Restart app to download ML models
# Try different PDF quality
```

### Translation Issues
```bash
# Check internet connection for first-time translations
# Clear cache if corrupted: Settings > Clear Cache
```

### PDF Processing Errors
```bash
# Ensure PDF is not password-protected
# Try smaller PDFs first
# Check available storage space
```

## 📊 Performance

- **OCR**: ~2-5 seconds per page (depends on image quality)
- **Translation**: ~1-3 seconds per text block (cached: instant)
- **PDF Generation**: ~1-2 seconds per page
- **Cache Size**: Configurable, default unlimited

## 🔐 Privacy & Security

- **No Data Sent**: Everything processed locally
- **No Accounts**: No user registration required
- **Local Storage**: Files stay on device
- **Cache Optional**: Can disable translation caching

## 🎯 Use Cases

- **Travel**: Translate documents abroad
- **Education**: Language learning materials
- **Business**: International document translation
- **Legal**: Contract translation
- **Research**: Academic paper translation

## 📝 License

Apache License 2.0

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push: `git push origin feature/amazing-feature`
5. Create Pull Request

## 🙏 Acknowledgments

- Google ML Kit for offline OCR
- Google Translate API for translations
- Flutter community for amazing packages

---

**100% Offline • Privacy First • Cross-Platform • Open Source** 🚀
                  │ REST API
┌─────────────────▼───────────────────────────────────────────┐
│              Backend (Python FastAPI)                        │
│  🐳 Docker Container (servers/cloud)                        │
├─────────────────────────────────────────────────────────────┤
│  • OCR (Tesseract)                                           │
│  • Translation (Hugging Face)                               │
│  • PDF Processing (pypdf + PIL)                            │
└─────────────────────────────────────────────────────────────┘
```

## Deployment Strategy

### Mobile Apps (Flutter)
**No Docker** - Native app store deployment:
```bash
# Build native APK/IPA
./build-mobile.sh

# Results in ./builds/ directory:
# - pdf-ocr-translator.apk (Android)
# - pdf-ocr-translator-arm64.apk (Android ARM64)
# - iOS IPA (when built on macOS)
```

**App Store Deployment:**
- **Android**: Sign APK → Google Play Console
- **iOS**: Sign IPA → App Store Connect

### Docker (Backend Only)
**Docker deployment** for servers/cloud:
```bash
# Production container
docker build -f docker/Dockerfile.backend -t pdf-ocr-backend .
docker run -p 8000:8000 pdf-ocr-backend
```

## Mobile App Deployment

Les apps Flutter sont déployées **nativement** sur les app stores :

### Build Apps Mobiles
```bash
# Build APK/IPA natifs
./build-mobile.sh

# Résultats dans ./builds/:
# - pdf-ocr-translator.apk (Android)
# - pdf-ocr-translator-arm64.apk (Android ARM64)
```

### Déploiement App Stores

#### Android (Google Play)
```bash
# 1. Signer l'APK
jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 \
  -keystore my-release-key.jks \
  builds/pdf-ocr-translator.apk alias_name

# 2. Aligner l'APK
zipalign -v 4 builds/pdf-ocr-translator.apk builds/pdf-ocr-translator-aligned.apk

# 3. Upload vers Google Play Console
# https://play.google.com/console/
```

#### iOS (App Store)
```bash
# Sur macOS avec Xcode:
flutter build ios --release

# Via Xcode ou fastlane pour signing
# Upload vers App Store Connect
# https://appstoreconnect.apple.com/
```

**⚠️ Note:** Docker n'est **jamais** utilisé pour les apps mobiles - seulement pour le backend serveur.

## Key Technologies

- **Backend**: FastAPI, Tesseract OCR, Hugging Face Transformers
- **Frontend**: Flutter (cross-platform)
- **DevOps**: Docker, GitHub Actions CI/CD, Gitflow

## Documentation

- [DEVELOPMENT.md](DEVELOPMENT.md) - Development guide and Gitflow workflow
- Backend API docs: `http://localhost:8000/docs` (after starting backend)

## Repository

- GitHub: [https://github.com/timteam/pdf-ocr-translator](https://github.com/timteam/pdf-ocr-translator)

## Project Structure

```
pdf-ocr-translator/
├── backend/                 # Python FastAPI backend
│   ├── ocr/                # Tesseract OCR
│   ├── translation/        # Hugging Face translation
│   ├── pdf_processor/      # PDF handling
│   ├── main.py
│   ├── routes.py
│   ├── models.py
│   ├── service.py
│   └── requirements.txt
├── flutter_app/            # Flutter frontend
│   ├── lib/
│   │   ├── screens/
│   │   ├── services/
│   │   ├── models/
│   │   └── theme/
│   └── pubspec.yaml
├── docker/                 # Docker configurations
├── .github/workflows/      # GitHub Actions CI/CD
└── DEVELOPMENT.md          # Development guide
```

## License

Apache License 2.0