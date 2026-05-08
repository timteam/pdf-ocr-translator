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
Frontend (Flutter: Linux/macOS/Windows/Android/iOS)
              ↓ REST API
Backend (Python FastAPI with:
  - OCR (Tesseract)
  - Translation (Hugging Face)
  - PDF Processing (pypdf))
```

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