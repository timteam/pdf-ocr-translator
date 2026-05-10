# PDF OCR Translator

Application de traduction PDF OCR entièrement locale — sans backend ni service distant

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20Desktop-green.svg)

---

## Présentation

`PDF OCR Translator` est une application Flutter conçue pour extraire du texte depuis des PDFs image, le traduire et générer une copie PDF traduite avec du texte superposé, traitée localement.

- Architecture 100 % client-side
- Aucun backend
- Pas de service cloud propre
- Traitement sur l'appareil

---

## Fonctionnalités (cahier des charges)

Ces fonctionnalités constituent les exigences du projet. Certaines sont déjà implémentées, d'autres sont en cours ou à venir.

- Extraction OCR depuis des pages PDF image
- Traduction dans plusieurs langues
- Génération d'un PDF de sortie avec textes en surimpression
- Indicateur de progression par page
- Confidentialité : aucune donnée envoyée vers un backend propriétaire
- Cache de traduction pour accélérer les traductions répétées
- Mode offline après première utilisation (grâce au cache)

---

## État d'implémentation

| Fonctionnalité | Statut | Notes |
|---|---|---|
| Sélection de PDF | Implémenté | Via `file_picker` |
| OCR (extraction de texte) | Implémenté | Tesseract CLI via `Process.run` + parsing TSV |
| Traduction | Implémenté | Via Google Translate API (réseau requis) + cache local JSON |
| Cache de traduction | Implémenté | Fichier `translation_cache.json` dans les documents de l'app |
| Génération PDF traduit | Implémenté | Image originale + overlay de texte traduit |
| Indicateur de progression | Implémenté | Pourcentage et étape en cours |
| Écran de résultat | Implémenté | Affichage du chemin du PDF de sortie |
| Build Linux desktop | Fonctionnel | Build release produit dans `flutter_app/build/linux/x64/release/bundle` |
| Packaging Snap | Configuré | Tesseract + 16 tessdata bundlés via `stage-packages` |
| Build Android / iOS | Non testé | Fichiers Flutter présents, build non validé |
| Mode offline complet | Partiel | Cache couvre les traductions déjà effectuées ; OCR 100 % local |

---

## Architecture globale

```
PDF Input (sélectionné par l'utilisateur)
   └──> Flutter App (client-side)
          ├── OCR
          │     └─ Tesseract CLI (Process.run → TSV → blocs texte + positions)
          ├── Traduction
          │     ├─ Google Translate API (via package `translator`, requiert réseau)
          │     └─ Cache JSON local (fichier dans documents de l'app)
          ├── Traitement PDF
          │     ├─ pdfx (lecture + rendu des pages en images PNG)
          │     └─ pdf (écriture du PDF de sortie avec overlays)
          └── Stockage local
                ├─ shared_preferences
                └─ getApplicationDocumentsDirectory()
```

> Note sur la traduction : le package `translator` est un wrapper non officiel de Google Translate. Il effectue des appels réseau. Le cache local compense partiellement cette contrainte pour les traductions déjà effectuées.

> Note sur l'OCR : Tesseract est appelé via son CLI (`Process.run`). Le binaire et les fichiers de langues (`tessdata`) doivent être disponibles sur le système en développement, ou sont bundlés dans le snap en production.

---

## Structure du projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/
│   │   │   ├── home_screen.dart
│   │   │   ├── processing_screen.dart
│   │   │   └── result_screen.dart
│   │   ├── services/
│   │   │   ├── ocr_service.dart
│   │   │   ├── pdf_service.dart
│   │   │   └── translation_service.dart
│   │   ├── models/
│   │   │   ├── language.dart
│   │   │   └── processing.dart
│   │   └── theme/
│   │       └── app_theme.dart
│   ├── assets/
│   │   ├── fonts/
│   │   ├── images/
│   │   └── icons/
│   ├── linux/
│   ├── android/
│   ├── ios/
│   ├── pubspec.yaml
│   └── test/
├── build-snap.sh
├── build-mobile.sh
├── snapcraft.yaml
├── SNAP-README.md
├── DEVELOPMENT.md
├── CONTRIBUTING.md
└── README.md
```

---

## Dépendances clés

### Flutter / Dart
- `flutter` SDK 3.16+
- `provider: ^6.0.0` — gestion d'état (utilisé dans `main.dart` et les écrans)
- `go_router: ^12.0.0` — navigation entre écrans
- `flutter_riverpod: ^2.4.0` — déclaré en dépendance, non utilisé dans le code actuel

### OCR
- Tesseract CLI — appelé via `dart:io` `Process.run`, pas de package Flutter
- Tessdata : fichiers de langues à installer séparément (voir prérequis)

### Traduction
- `translator: ^1.0.0` — wrapper Google Translate (appels réseau)
- `flutter_translate: ^4.1.0` — déclaré, non utilisé activement

### PDF
- `pdfx: ^2.4.0` — lecture PDF, rendu de pages en images
- `pdf: ^3.10.0` — génération du PDF de sortie
- `printing: ^5.12.0` — aperçu et impression

### Stockage & fichiers
- `shared_preferences: ^2.2.0`
- `path_provider: ^2.1.0`
- `file_picker: ^6.0.0`
- `path: ^1.8.3`

### Image
- `image: ^4.1.0`

### Permissions & UI
- `permission_handler: ^11.0.0`
- `material_design_icons_flutter: ^7.0.0`
- `flutter_svg: ^2.0.0`
- `shimmer: ^3.0.0`
- `fluttertoast: ^8.2.0`
- `awesome_dialog: ^3.1.0`

### Utilitaires
- `logger: ^2.0.0`
- `intl: ^0.19.0`
- `uuid: ^4.0.0`

---

## Langues supportées

16 langues définies dans `language.dart` :

| Code | Langue |
|------|--------|
| `en` | English |
| `fr` | Français |
| `es` | Español |
| `de` | Deutsch |
| `it` | Italiano |
| `pt` | Português |
| `nl` | Nederlands |
| `pl` | Polski |
| `ru` | Русский |
| `ja` | 日本語 |
| `zh` | 中文 |
| `ko` | 한국어 |
| `ar` | العربية |
| `hi` | हिन्दी |
| `th` | ไทย |
| `vi` | Tiếng Việt |

---

## Fonctionnement interne

1. L'utilisateur sélectionne un PDF via `file_picker`.
2. Le PDF est chargé page par page avec `pdfx` (rendu en image PNG via PDFium).
3. Chaque image de page est envoyée à Google ML Kit pour extraire les blocs de texte et leurs positions (`boundingBox`).
4. Chaque bloc est traduit via `translator` (Google Translate API) — le cache local est consulté en priorité.
5. Un PDF de sortie est généré avec `pdf` : chaque page affiche l'image originale + des overlays de texte traduit positionnés sur les bounding boxes OCR.
6. Le PDF de sortie est sauvegardé dans `getApplicationDocumentsDirectory()`.
7. Le PDF original n'est pas modifié.

---

## Prérequis de build

### Linux desktop

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build clang++ pkg-config libgtk-3-dev libglib2.0-dev liblzma-dev
```

Tesseract et les données de langues utilisées par l'app :

```bash
sudo apt install \
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-fra \
  tesseract-ocr-deu \
  tesseract-ocr-spa \
  tesseract-ocr-ita \
  tesseract-ocr-por \
  tesseract-ocr-nld \
  tesseract-ocr-pol \
  tesseract-ocr-rus \
  tesseract-ocr-jpn \
  tesseract-ocr-chi-sim \
  tesseract-ocr-kor \
  tesseract-ocr-ara \
  tesseract-ocr-hin \
  tesseract-ocr-tha \
  tesseract-ocr-vie
```

> En production (snap), Tesseract et les tessdata sont bundlés automatiquement via `stage-packages` dans `snapcraft.yaml`.

Flutter doit être installé et accessible dans le `PATH` :

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
flutter config --enable-linux-desktop
```

### Snap (Linux uniquement)

```bash
sudo snap install snapcraft --classic
```

---

## Procédure de build

### 1. Installer les dépendances Flutter

```bash
cd flutter_app
flutter pub get
```

### 2. Tester en mode développement

```bash
flutter run -d linux
```

### 3. Build Linux release

```bash
flutter build linux --release
```

Le binaire est produit dans :
```
flutter_app/build/linux/x64/release/bundle/pdf_ocr_translator
```

### 4. Build Snap Linux

```bash
cd /home/tim/Repos/pdf-ocr-translator
./build-snap.sh
```

Le script suppose que le build Linux release a été effectué au préalable.

### 5. Build mobile (non validé)

```bash
flutter build apk --release          # Android
flutter build ios --release          # macOS uniquement
```

---

## Packaging Snap

### Fichiers

- `snapcraft.yaml` — configuration snap (confinement strict, base core22)
- `build-snap.sh` — script de build snap automatisé
- `SNAP-README.md` — instructions dédiées au packaging snap

### Installation locale du snap

```bash
sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous
```

### Exécution

```bash
pdf-ocr-translator
```

---

## Tests

```bash
cd flutter_app
flutter test
```

Tests manuels à effectuer :
- Ouverture et sélection d'un PDF
- Extraction OCR (vérifier que le texte est bien détecté)
- Traduction de texte (vérifier que les appels réseau fonctionnent)
- Génération du PDF de sortie
- Comportement en mode offline (cache)

---

## Problèmes connus

- La traduction nécessite une connexion Internet (Google Translate API). Le mode offline total n'est pas encore atteint.
- `flutter_riverpod` est dans `pubspec.yaml` mais non utilisé dans le code actuel.
- Tesseract doit être installé sur le système hôte pour le développement (`tesseract` doit être dans le `PATH`).

---

## Branches

- `main` — branche principale
- `feature/pdf-ocr-translator-setup` — branche courante, contient le packaging snap et la structure de l'app

---

## Licence

Apache License 2.0

## Contribuer

1. Fork du dépôt
2. Créer une branche : `git checkout -b feature/ma-fonctionnalite`
3. Commit : `git commit -m 'feat: description'`
4. Push : `git push origin feature/ma-fonctionnalite`
5. Créer une Pull Request
