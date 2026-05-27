# PDF OCR Translator

Application de traduction PDF entièrement locale — sans backend ni service distant

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20Desktop-green.svg)

---

## Présentation

`PDF OCR Translator` est une application Flutter Linux desktop qui extrait du texte depuis des PDFs image via OCR, le traduit, et génère un PDF de sortie avec le texte traduit superposé sur chaque page. Tout le traitement se fait localement sur l'appareil — aucune donnée n'est envoyée vers un serveur tiers.

---

## Fonctionnalités

- Extraction OCR depuis des pages PDF image (PaddleOCR PP-OCRv4)
- Détection automatique de la langue source page par page (FastText LID + PaddleOCR)
- Confirmation et personnalisation par page avant traduction
- Traduction hors-ligne vers plusieurs langues (Opus-MT via CTranslate2)
- Génération d'un PDF de sortie avec textes en surimpression
- Choix du chemin et nom du fichier de sortie avant le lancement
- Indicateur de progression détaillé par page et par étape
- Mode debug : images intermédiaires et logs exportés dans un répertoire configurable

---

## État d'implémentation

| Fonctionnalité | Statut | Notes |
|---|---|---|
| Sélection du PDF source | Implémenté | Via `file_picker` |
| Choix du fichier de sortie | Implémenté | Dialog pré-rempli, bouton "Parcourir…" |
| Rendu des pages en images | Implémenté | `pdftoppm` à 150 DPI |
| OCR | Implémenté | PaddleOCR PP-OCRv4 server models, subprocess Python |
| Détection de langue | Implémenté | 3 passes PaddleOCR + FastText LID 176 langues |
| Traduction | Implémenté | Opus-MT (Helsinki-NLP), CTranslate2 + sentencepiece, 100 % hors-ligne |
| Modèles de traduction | Téléchargement au premier usage | ~50 MB par paire de langues, depuis HuggingFace |
| Confirmation des langues | Implémenté | Écran de validation page par page avec miniature zoomable |
| Génération PDF par page | Implémenté | `compute()` Flutter — isolate de fond |
| Assemblage du document final | Implémenté | `pdfunite` (poppler-utils) |
| Progression détaillée | Implémenté | Cercle global + barre d'étape |
| Build Linux desktop | Fonctionnel | `flutter_app/build/linux/x64/release/bundle/` |
| Packaging Snap | Fonctionnel | Python env, PaddleOCR et poppler-utils bundlés |

---

## Architecture globale

```
PDF source (sélectionné par l'utilisateur)
   │
   ├─ pdfinfo              → nombre de pages
   │
   └─ Phase 1 — Détection de langue (par page) :
        ├─ pdftoppm 150DPI → image PNG (miniature)
        └─ paddleocr.py    → 3 passes (ch → japan → en) + analyse Unicode
           └─ fasttext_detect.py → classification FastText LID si script latin
   │
   └─ Écran de confirmation — résumé par page, personnalisation optionnelle
   │
   └─ Phase 2 — Traduction (par page) :
        ├─ pdftoppm 300DPI → image PNG haute résolution
        ├─ paddleocr.py    → blocs texte + bounding boxes
        ├─ opusmt_translate.py → Opus-MT (CTranslate2 + sentencepiece)
        └─ compute()       → PDF de la page (isolate de fond)
                                  │
                                  └─ fichier PDF temporaire
   │
   └─ pdfunite             → assemblage en fichier de destination
```

**Outils système requis :**
- `poppler-utils` — fournit `pdfinfo`, `pdftoppm`, `pdfunite`
- `python3` — exécute les scripts OCR, détection et traduction

**Scripts Python bundlés (`assets/scripts/`) :**
- `paddleocr.py` — extraction OCR et détection de script via PaddleOCR
- `fasttext_detect.py` — classification de langue via FastText LID (`lid.176.ftz`)
- `opusmt_translate.py` — traduction par lot via Opus-MT / CTranslate2

**Packages Flutter actifs :**
- `pdf`, `image` — génération des pages PDF avec overlay
- `go_router` — navigation
- `file_picker` — sélection du PDF source et du fichier de sortie
- `path_provider`, `path`, `logger`, `permission_handler`

---

## Structure du projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart                    # Bootstrap, GoRouter, pré-chargement modèles
│   │   ├── screens/
│   │   │   ├── home_screen.dart         # Sélection PDF + langue cible + dialog sortie
│   │   │   ├── processing_screen.dart   # Détection langue → confirmation → traduction
│   │   │   └── result_screen.dart       # Affichage du fichier produit
│   │   ├── services/
│   │   │   ├── pdf_service.dart         # Pipeline complet (pdfinfo/pdftoppm/pdfunite/compute)
│   │   │   ├── ocr_service.dart         # PaddleOCR + FastText LID — détection et OCR
│   │   │   └── translation_service.dart # Opus-MT — téléchargement + traduction par lot
│   │   ├── models/
│   │   │   ├── language.dart            # 16 langues supportées
│   │   │   ├── language_detection.dart  # PageLanguage (code détecté, surcharge, miniature)
│   │   │   ├── processing.dart          # ProcessingUpdate (progression)
│   │   │   └── app_logger.dart          # Logger + répertoire debug
│   │   └── theme/
│   │       └── app_theme.dart
│   ├── assets/
│   │   ├── fonts/                       # Roboto Regular/Bold/Italic
│   │   ├── models/                      # lid.176.ftz (FastText LID, ~900 KB)
│   │   └── scripts/                     # paddleocr.py, fasttext_detect.py, opusmt_translate.py
│   ├── linux/
│   └── pubspec.yaml
├── scripts/
│   ├── download_fasttext_model.sh       # Télécharge lid.176.ftz (Meta / HuggingFace)
│   └── download_pip_wheels.sh           # Télécharge les wheels Python pour le snap
├── snapcraft.yaml                       # Snap (core24, confinement strict)
├── build-snap.sh                        # Script de build complet
└── README.md
```

---

## Flux utilisateur

1. **HomeScreen** — sélection du PDF source, choix de la langue cible, chemin de sortie
2. **Phase détection** — pour chaque page : miniature 150 DPI + détection automatique de langue
3. **Écran de confirmation** — liste des pages avec langue détectée et miniature zoomable ; option "Personnaliser" pour surcharger par page ou pour l'ensemble du document
4. **Phase traduction** — pour chaque page : OCR 300 DPI → Opus-MT → PDF de page (isolate)
5. **Assemblage** — `pdfunite` fusionne tous les PDFs de pages → fichier de destination
6. **ResultScreen** — chemin du fichier produit

---

## Langues supportées

16 langues définies dans `language.dart` :

| Code | Langue | Script |
|------|--------|--------|
| `en` | English | Latin |
| `fr` | Français | Latin |
| `es` | Español | Latin |
| `de` | Deutsch | Latin |
| `it` | Italiano | Latin |
| `pt` | Português | Latin |
| `nl` | Nederlands | Latin |
| `pl` | Polski | Latin |
| `ru` | Русский | Cyrillique |
| `ja` | 日本語 | Japonais |
| `zh` | 中文 | CJK |
| `ko` | 한국어 | Hangul |
| `ar` | العربية | Arabe |
| `hi` | हिन्दी | Devanagari |
| `th` | ไทย | Thaï |
| `vi` | Tiếng Việt | Latin (diacritiques) |

La détection de langue est automatique. Les modèles de traduction Opus-MT sont téléchargés depuis HuggingFace au premier usage (~50 MB par paire).

---

## Installation (utilisateur final)

Le snap est autonome : Python, PaddleOCR, FastText, CTranslate2 et poppler-utils sont **bundlés**. Aucune dépendance à installer manuellement.

```bash
sudo snap install pdf-ocr-translator   # depuis le Snap Store (à venir)
snap run pdf-ocr-translator
```

La connexion au content snap GTK3 (`gnome-46-2404`) est établie automatiquement par le Snap Store.

---

## Build depuis les sources

### Ce dont tu as besoin sur ta machine

| Outil | Installation | Rôle |
|---|---|---|
| Flutter SDK | voir ci-dessous | compiler l'application |
| `build-essential`, `cmake`, `ninja-build`, `clang`, `pkg-config`, `libgtk-3-dev` | `apt install` | toolchain de build Flutter Linux |
| Snapcraft | `snap install snapcraft --classic` | packager le snap |
| `gnome-46-2404` | `snap install gnome-46-2404` | content snap GTK3 (runtime + build) |

```bash
# Toolchain Flutter Linux
sudo apt update && sudo apt install \
  build-essential cmake ninja-build clang pkg-config libgtk-3-dev

# Flutter SDK
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
flutter config --enable-linux-desktop

# Snapcraft
sudo snap install snapcraft --classic
sudo snap install gnome-46-2404
```

> Pas besoin d'installer Python, PaddleOCR ou poppler-utils : ils sont téléchargés et
> bundlés automatiquement dans le snap lors du build.

### Premier build (après clonage)

```bash
# Installer les dépendances Flutter
cd flutter_app && flutter pub get && cd ..

# Lancer le build complet
bash build-snap.sh
```

`build-snap.sh` orchestre automatiquement :
1. Téléchargement du modèle FastText LID (`lid.176.ftz`, ~900 KB) si absent
2. Téléchargement des wheels Python si absentes (`paddlepaddle` ~185 MB + dépendances)
3. Build Flutter Linux release (ignoré si les sources `.dart` n'ont pas changé)
4. Build snapcraft incrémental (seules les parties modifiées sont reconstruites)

Le premier build prend **20–30 min** (téléchargements + compilation). Les suivants sont bien plus rapides.

### Builds suivants

```bash
bash build-snap.sh          # build incrémental — ~3–5 min
bash build-snap.sh --clean  # rebuild complet depuis zéro — ~15 min
```

`--clean` est nécessaire uniquement après avoir modifié des `stage-packages` dans `snapcraft.yaml`. Si le fichier a changé sans `--clean`, le script affiche un avertissement.

### Installation et test du snap produit (développement)

```bash
bash install-local.sh
snap run pdf-ocr-translator
```

`install-local.sh` installe le snap et établit manuellement la connexion au content snap GTK3 (`gnome-46-2404`). Cette étape est nécessaire en local car l'installation avec `--dangerous` (fichier local) bypass le Snap Store, qui établit normalement cette connexion automatiquement. En production (Snap Store), aucune commande supplémentaire n'est requise.

### Mode développement Flutter (sans snap)

Pour itérer rapidement sur l'interface sans passer par snapcraft :

```bash
# Prérequis supplémentaires (non nécessaires pour le build snap)
sudo apt install poppler-utils python3-pip
pip3 install paddlepaddle paddleocr ctranslate2 sentencepiece fasttext-wheel

cd flutter_app
flutter run -d linux
```

---

## Dépendances clés

### Packages Flutter

| Package | Version | Usage |
|---|---|---|
| `go_router` | `^17.0.0` | Navigation |
| `file_picker` | `^11.0.0` | Sélection fichiers (source + destination) |
| `pdf` | `^3.10.0` | Génération PDF par page avec overlay |
| `image` | `^4.1.0` | Décodage PNG pour calcul dimensions |
| `path_provider` | `^2.1.0` | Chemins système |
| `path` | `^1.8.3` | Manipulation de chemins |
| `logger` | `^2.0.0` | Logging |
| `permission_handler` | `^12.0.0` | Permissions fichiers |

### Packages Python (bundlés dans le snap)

| Package | Usage |
|---|---|
| `paddlepaddle` | Moteur PaddleOCR (PP-OCRv4) |
| `paddleocr` | OCR multi-langues + détection de script |
| `ctranslate2` | Inférence Opus-MT rapide sur CPU |
| `sentencepiece` | Tokenisation pour Opus-MT |
| `fasttext-wheel` | Classification de langue FastText LID |

### Outils système

| Outil | Paquet apt | Usage |
|---|---|---|
| `pdfinfo` | `poppler-utils` | Comptage des pages |
| `pdftoppm` | `poppler-utils` | Rendu page → PNG |
| `pdfunite` | `poppler-utils` | Assemblage PDF final |

---

## Licence

Apache License 2.0

## Contribuer

1. Fork du dépôt
2. Créer une branche : `git checkout -b feature/ma-fonctionnalite`
3. Commit : `git commit -m 'feat: description'`
4. Push : `git push origin feature/ma-fonctionnalite`
5. Créer une Pull Request
