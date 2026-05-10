# PDF OCR Translator

Application de traduction PDF OCR entièrement locale — sans backend ni service distant

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20Desktop-green.svg)

---

## Présentation

`PDF OCR Translator` est une application Flutter Linux desktop qui extrait du texte depuis des PDFs image via OCR, le traduit, et génère un PDF de sortie avec le texte traduit superposé sur chaque page. Tout le traitement se fait localement sur l'appareil, sans backend ni cloud propriétaire.

---

## Fonctionnalités (cahier des charges)

- Extraction OCR depuis des pages PDF image
- Traduction dans plusieurs langues
- Génération d'un PDF de sortie avec textes en surimpression
- Choix du chemin et nom du fichier de sortie avant le lancement
- Indicateur de progression détaillé par page et par étape
- Confidentialité : aucune donnée envoyée vers un backend propriétaire
- Cache de traduction pour accélérer les traductions répétées
- Mode offline après première utilisation (grâce au cache)

---

## État d'implémentation

| Fonctionnalité | Statut | Notes |
|---|---|---|
| Sélection du PDF source | Implémenté | Via `file_picker` |
| Choix du fichier de sortie | Implémenté | Dialog pré-rempli avec `source_lang.pdf` dans le même dossier, bouton "Parcourir…" |
| Rendu des pages en images | Implémenté | `pdftoppm` (poppler-utils) à 150 DPI |
| OCR | Implémenté | Tesseract CLI, sortie TSV, groupement par paragraphe |
| Traduction | Implémenté | Google Translate API (réseau requis) + cache JSON local |
| Cache de traduction | Implémenté | `translation_cache.json` dans les documents de l'app |
| Génération PDF par page | Implémenté | `compute()` Flutter — exécuté dans un isolate de fond (UI non bloquée) |
| Assemblage du document final | Implémenté | `pdfunite` (poppler-utils) |
| Progression détaillée | Implémenté | Cercle global + barre d'étape avec % + barre indéterminée pour l'assemblage |
| Build Linux desktop | Fonctionnel | `flutter_app/build/linux/x64/release/bundle/` |
| Packaging Snap | Fonctionnel | Tesseract, tessdata (16 langues) et poppler-utils bundlés |
| Build Android / iOS | Non validé | Structure Flutter présente, build non testé |
| Mode offline complet | Partiel | OCR 100 % local ; traduction nécessite le réseau sauf si cachée |

---

## Architecture globale

```
PDF source (sélectionné par l'utilisateur)
   │
   ├─ pdfinfo          → nombre de pages
   │
   └─ Pour chaque page :
        ├─ pdftoppm    → image PNG (150 DPI)
        ├─ tesseract   → TSV → blocs texte + bounding boxes
        ├─ translator  → Google Translate API + cache JSON local
        └─ compute()   → PDF de la page (isolate de fond)
                              │
                              └─ fichier PDF temporaire
   │
   └─ pdfunite         → assemblage en fichier de destination
```

**Outils système requis :**
- `poppler-utils` — fournit `pdfinfo`, `pdftoppm`, `pdfunite`
- `tesseract-ocr` + fichiers `tessdata` par langue

**Packages Flutter actifs :**
- `pdf` — génération des pages PDF avec overlay
- `image` — décodage PNG pour calcul des dimensions en points
- `translator` — wrapper Google Translate
- `provider` + `go_router` — state management et navigation
- `file_picker` — sélection du PDF source et du fichier de sortie
- `path_provider`, `path`, `logger`, `shared_preferences`

> La traduction utilise le package `translator`, wrapper non officiel de Google Translate. Elle nécessite le réseau. Le cache local JSON prend le relais pour les textes déjà traduits.

---

## Structure du projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart                    # Bootstrap, Provider, GoRouter
│   │   ├── screens/
│   │   │   ├── home_screen.dart         # Sélection PDF + langues + dialog sortie
│   │   │   ├── processing_screen.dart   # Progression globale + étape courante
│   │   │   └── result_screen.dart       # Affichage du fichier produit
│   │   ├── services/
│   │   │   ├── pdf_service.dart         # Pipeline complet (pdfinfo/pdftoppm/pdfunite/compute)
│   │   │   ├── ocr_service.dart         # Tesseract CLI → TSV → OCRTextBlock[]
│   │   │   └── translation_service.dart # GoogleTranslator + cache JSON
│   │   ├── models/
│   │   │   ├── language.dart            # 16 langues supportées
│   │   │   └── processing.dart          # ProcessingUpdate (progression)
│   │   └── theme/
│   │       └── app_theme.dart
│   ├── assets/fonts/
│   ├── linux/
│   ├── pubspec.yaml
│   └── test/
├── snapcraft.yaml                       # Snap (core22, confinement strict)
├── build-snap.sh                        # Script de build snap
├── SNAP-README.md
├── DEVELOPMENT.md
├── CONTRIBUTING.md
└── README.md
```

---

## Flux utilisateur

1. **HomeScreen** — sélection du PDF source, choix des langues source et cible
2. **Dialog "Fichier de sortie"** — chemin pré-rempli (`même_dossier/nom_lang.pdf`), modifiable, bouton "Parcourir…"
3. **ProcessingScreen** — pour chaque page :
   - Rendu PNG (`pdftoppm`)
   - Extraction OCR (`tesseract`, TSV)
   - Traduction bloc par bloc (avec cache)
   - Écriture du PDF de page dans un isolate (`compute`)
   - Indicateur global (cercle %) + indicateur d'étape (barre linéaire %)
4. **Assemblage** — `pdfunite` fusionne tous les PDFs de pages → fichier de destination (barre indéterminée)
5. **ResultScreen** — chemin du fichier produit

---

## Langues supportées

16 langues définies dans `language.dart`, mappées vers les codes Tesseract dans `ocr_service.dart` :

| App | Tesseract | Langue |
|-----|-----------|--------|
| `en` | `eng` | English |
| `fr` | `fra` | Français |
| `es` | `spa` | Español |
| `de` | `deu` | Deutsch |
| `it` | `ita` | Italiano |
| `pt` | `por` | Português |
| `nl` | `nld` | Nederlands |
| `pl` | `pol` | Polski |
| `ru` | `rus` | Русский |
| `ja` | `jpn` | 日本語 |
| `zh` | `chi_sim` | 中文 |
| `ko` | `kor` | 한국어 |
| `ar` | `ara` | العربية |
| `hi` | `hin` | हिन्दी |
| `th` | `tha` | ไทย |
| `vi` | `vie` | Tiếng Việt |

---

## Prérequis de build

### Linux desktop

```bash
sudo apt update
sudo apt install \
  build-essential cmake ninja-build clang++ pkg-config \
  libgtk-3-dev libglib2.0-dev liblzma-dev \
  poppler-utils
```

Tesseract et les tessdata :

```bash
sudo apt install \
  tesseract-ocr \
  tesseract-ocr-eng tesseract-ocr-fra tesseract-ocr-deu tesseract-ocr-spa \
  tesseract-ocr-ita tesseract-ocr-por tesseract-ocr-nld tesseract-ocr-pol \
  tesseract-ocr-rus tesseract-ocr-jpn tesseract-ocr-chi-sim tesseract-ocr-kor \
  tesseract-ocr-ara tesseract-ocr-hin tesseract-ocr-tha tesseract-ocr-vie
```

Flutter SDK :

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
flutter config --enable-linux-desktop
```

> En production (snap), `poppler-utils`, `tesseract-ocr` et les 16 tessdata sont bundlés via `stage-packages` dans `snapcraft.yaml`. L'utilisateur final n'a rien à installer.

### Snap

```bash
sudo snap install snapcraft --classic
```

---

## Procédure de build

### 1. Dépendances Flutter

```bash
cd flutter_app
flutter pub get
```

### 2. Mode développement

```bash
flutter run -d linux
```

### 3. Build Linux release

```bash
flutter build linux --release
```

Binaire produit dans :
```
flutter_app/build/linux/x64/release/bundle/pdf_ocr_translator
```

### 4. Build Snap

```bash
cd /chemin/vers/pdf-ocr-translator
bash build-snap.sh
```

Le script compile le bundle Flutter, puis lance `snapcraft` qui télécharge et bundle `poppler-utils`, `tesseract-ocr` et les tessdata.

### 5. Installation locale du snap

```bash
sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous
pdf-ocr-translator
```

### 6. Build mobile (non validé)

```bash
flutter build apk --release
flutter build ios --release   # macOS uniquement
```

---

## Dépendances clés

### Packages Flutter actifs

| Package | Usage |
|---|---|
| `provider: ^6.0.0` | Gestion d'état |
| `go_router: ^12.0.0` | Navigation |
| `file_picker: ^6.0.0` | Sélection fichiers (source + destination) |
| `pdf: ^3.10.0` | Génération PDF par page avec overlay |
| `image: ^4.1.0` | Décodage PNG pour calcul dimensions |
| `translator: ^1.0.0` | Wrapper Google Translate (réseau) |
| `shared_preferences: ^2.2.0` | Persistance légère |
| `path_provider: ^2.1.0` | Chemins système |
| `path: ^1.8.3` | Manipulation de chemins |
| `logger: ^2.0.0` | Logging |
| `permission_handler: ^11.0.0` | Permissions fichiers |
| `printing: ^5.12.0` | Déclaré, non utilisé activement |

### Packages déclarés, non utilisés dans le code actuel

| Package | Raison |
|---|---|
| `flutter_riverpod: ^2.4.0` | Remplacé par `provider` |
| `flutter_translate: ^4.1.0` | Non intégré |
| `pdfx: ^2.4.0` | Rendu remplacé par `pdftoppm` |
| `shimmer`, `fluttertoast`, `awesome_dialog`, etc. | UI non finalisée |

### Outils système

| Outil | Paquet apt | Usage |
|---|---|---|
| `pdfinfo` | `poppler-utils` | Comptage des pages |
| `pdftoppm` | `poppler-utils` | Rendu page → PNG |
| `pdfunite` | `poppler-utils` | Assemblage PDF final |
| `tesseract` | `tesseract-ocr` | Extraction OCR |
| tessdata | `tesseract-ocr-[lang]` | Modèles par langue |

---

## Problèmes connus

- La traduction nécessite une connexion Internet (Google Translate API). Le mode offline complet n'est pas encore atteint.
- `flutter_riverpod`, `pdfx`, `flutter_translate` et quelques packages UI sont déclarés dans `pubspec.yaml` mais non utilisés.
- La génération PDF par page utilise `compute()` (isolate Flutter) pour rester non bloquante — l'approche est validée sur 110 pages.
- `pdfunite` doit être installé sur le système hôte en développement (inclus dans `poppler-utils`).

---

## Branches

- `main` — branche principale
- `feature/pdf-ocr-translator-setup` — branche courante

---

## Licence

Apache License 2.0

## Contribuer

1. Fork du dépôt
2. Créer une branche : `git checkout -b feature/ma-fonctionnalite`
3. Commit : `git commit -m 'feat: description'`
4. Push : `git push origin feature/ma-fonctionnalite`
5. Créer une Pull Request
