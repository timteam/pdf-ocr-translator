# PDF OCR Translator

🌍 **Open source solution for PDF OCR and translation across all platforms: Linux, macOS, Windows, Android, and iOS.**

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Status](https://img.shields.io/badge/Status-Active%20Development-green.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Python](https://img.shields.io/badge/Python-3.11+-green.svg)

## Features ✨

- 📄 **PDF Processing**: Extract text from PDF images without modifying originals
- 🌐 **100+ Languages**: Translate to over 100 languages including Asian languages
- 🎯 **OCR Technology**: Advanced text extraction using Tesseract 5.x
- 📊 **Progress Tracking**: Real-time processing status and detailed logging
- 🚀 **Cross-Platform**: Native support for Linux, macOS, Windows, Android, and iOS
- 🔒 **Offline Processing**: All resources are local - no cloud dependencies
- 📝 **Detailed Logs**: JSON-formatted logs for each page processed

## Quick Start

### Backend Setup
```bash
cd backend
python -m venv venv
source venv/bin/activate  # or venv\Scripts\activate on Windows
pip install -r requirements.txt
python main.py
```

### Frontend Setup
```bash
cd flutter_app
flutter pub get
flutter run
```

### Docker
```bash
docker-compose -f docker/docker-compose.yml up -d
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Frontend (Flutter)                        │
│  Linux | macOS | Windows | Android | iOS                   │
│  📦 Native Apps (APK/IPA) for App Stores                   │
└─────────────────┬───────────────────────────────────────────┘
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