# PDF OCR Translator

🌍 **Application de traduction PDF OCR entièrement locale — sans backend ni service distant**

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Offline](https://img.shields.io/badge/Offline-First-green.svg)

---

## 📘 Présentation

`PDF OCR Translator` est une application Flutter conçue pour extraire du texte depuis des PDFs image, le traduire et générer une copie PDF traduite avec du texte superposé localement.

- 100 % client-side
- Aucun backend
- Pas de service cloud
- Traitement sur l’appareil
- Compatible Linux / Windows / macOS / Android / iOS

---

## ✨ Fonctionnalités principales

- 📄 Extraction OCR depuis des pages PDF image
- 🌐 Traduction dans plusieurs langues
- 🖨️ Génération d’un PDF de sortie avec textes en surimpression
- 📈 Indicateur de progression par page
- 🔒 Confidentialité garantie : tout reste local
- 💾 Cache de traduction pour accélérer les traductions répétées
- ✅ Mode offline après première utilisation

---

## 🏗️ Architecture globale

```
PDF Input
   └──> Flutter App (Client)
          ├── OCR
          │     ├─ Google ML Kit
          │     └─ Tesseract fallback
          ├── Traduction
          │     ├─ Google Translate API localisée
          │     └─ cache JSON local
          ├── Traitement PDF
          │     ├─ pdfx (lecture)
          │     └─ pdf (écriture)
          └── Stockage local
                ├─ shared_preferences
                └─ system files
```

---

## 🧩 Structure du projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/
│   │   ├── services/
│   │   ├── models/
│   │   └── theme/
│   ├── android/
│   ├── ios/
│   ├── pubspec.yaml
│   └── test/
├── build-snap.sh
├── snapcraft.yaml
├── SNAP-README.md
└── README.md
```

---

## 🔧 Dépendances clés

### Flutter / Dart
- `flutter` SDK 3.16+
- `provider` pour l’état
- `go_router` pour la navigation
- `flutter_riverpod` pour l’injection de dépendances

### OCR
- `google_ml_kit: ^0.16.0`
- `tesseract_ocr: ^0.5.0`

### Traduction
- `translator: ^1.0.0`
- `flutter_translate: ^4.1.0`

### PDF
- `pdfx: ^2.4.0`
- `pdf: ^3.10.0`
- `printing: ^5.12.0`

### Stockage & fichiers
- `shared_preferences: ^2.2.0`
- `path_provider: ^2.1.0`
- `file_picker: ^6.0.0`

### Permissions & UI
- `permission_handler: ^11.0.0`
- `material_design_icons_flutter: ^7.0.0`
- `flutter_svg: ^2.0.0`
- `shimmer: ^3.0.0`
- `fluttertoast: ^8.2.0`
- `awesome_dialog: ^3.1.0`

### Utilitaires
- `image: ^4.1.0`
- `logger: ^2.0.0`
- `intl: ^0.19.0`
- `uuid: ^4.0.0`

> Note : la version de `tesseract_ocr` a été ajustée à `^0.5.0` pour garantir la résolution de dépendances Flutter.

---

## 🛠️ Environnements supportés

### Environnement de développement

- **Linux** : recommandé pour la génération du snap
- **macOS** : utile pour iOS et macOS
- **Windows** : utile pour Windows

### Environnement de build

- `Flutter SDK` installé et accessible dans le `PATH`
- `flutter pub get` doit réussir dans `flutter_app`
- **Linux** requis pour la génération du snap `snapcraft`
- `snapcraft` installé via `sudo snap install snapcraft --classic`
- Desktop Linux support should be enabled with `flutter config --enable-linux-desktop`

> Important : la génération du snap est conçue pour être faite sur un hôte Linux. Le script `build-snap.sh` vérifie cela.

### Linux build prerequisites

For Linux desktop and snap builds, install these packages on Debian/Ubuntu:

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build clang++ pkg-config libgtk-3-dev libglib2.0-dev liblzma-dev
```

If `flutter pub get` warns about `file_picker` desktop plugin references, the issue is related to the package plugin metadata and may not block build if the desktop platform implementation is available. If the build fails, consider using the stable `file_picker` version that matches your Flutter SDK or switching to a desktop-friendly file picker package.

---

## 🚀 Procédure de build détaillée

### 1. Installer les prérequis

#### Linux

```bash
sudo snap install snapcraft --classic
```

Installer Flutter selon la documentation officielle :

```bash
# Exemple d’installation simple
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
```

#### macOS

- Installer Flutter
- Installer Xcode
- Installer CocoaPods si nécessaire

#### Windows

- Installer Flutter
- Installer Visual Studio avec les charges de travail Desktop
- Installer Android Studio pour Android

---

### 2. Installer les dépendances Flutter

```bash
cd flutter_app
flutter pub get
```

### 3. Tester localement

```bash
flutter run
```

### 4. Build mobile

```bash
flutter build apk --release
flutter build ios --release   # sur macOS seulement
```

### 5. Build desktop

```bash
flutter build linux --release
flutter build windows --release
flutter build macos --release
```

### 6. Build Snap Linux

```bash
cd /home/tim/Repos/pdf-ocr-translator
./build-snap.sh
```

Si le projet n’a pas encore de dossier `linux/`, le script génère automatiquement le support desktop Linux.

---

## 📦 Packaging Snap

### Fichiers importants

- `snapcraft.yaml` : configuration snap
- `build-snap.sh` : script de build snap automatisé
- `SNAP-README.md` : instructions de packaging snap

### Installation locale du snap

```bash
sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous
```

### Exécution

```bash
pdf-ocr-translator
```

---

## 💡 Fonctionnement interne

1. Le PDF sélectionné est converti en images page par page.
2. Chaque image est envoyée à l’OCR pour extraire le texte.
3. Les blocs de texte sont traduits dans la langue cible.
4. Un PDF de sortie est généré avec des zones de texte surimprimées.
5. Le PDF original n’est pas modifié : seule une copie traduite est créée.

---

## 🔍 Détails techniques

### OCR

- **Google ML Kit** pour l’extraction principale
- **Tesseract** en fallback si nécessaire

### Traduction

- Utilise la couche `translator`
- Contrôle local du cache pour accélérer les requêtes
- Possibilité de fonctionner offline après premières requêtes

### PDF

- Lecture avec `pdfx`
- Génération et mise en page avec `pdf`
- Texte traduit ajouté en surimpression sur la page

---

## 🧪 Tests et validation

```bash
cd flutter_app
flutter test
```

### Tests complémentaires

- Vérifier l’ouverture du PDF dans l’app
- Vérifier l’extraction OCR
- Vérifier la traduction de texte
- Vérifier la génération du fichier PDF de sortie

---

## ⚠️ Problèmes connus

- `flutter build linux` nécessite le support desktop Linux configuré
- `snapcraft` doit être installé sur Linux
- Certains packages Flutter peuvent devoir être ajustés si les versions changent

---

## 📋 Notes de release

- `feature/pdf-ocr-translator-setup` contient le packaging snap
- `build-snap.sh` génère le binaire Linux, puis le package snap
- `README.md` couvre la procédure complète
- `SNAP-README.md` donne une alternative dédiée au packaging snap

---

## 📝 Conclusion

Cette solution est conçue pour fournir une application PDF OCR + traduction 100 % locale, multi-plateforme et compatible avec les exigences modernes de confidentialité et d’App Store. Le processus de build est également documenté pour permettre la génération native et la distribution Linux via snap.


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