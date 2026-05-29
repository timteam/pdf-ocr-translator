# PDF OCR Translator

Application de traduction PDF entièrement locale — sans backend ni service distant

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20Desktop-green.svg)

---

## Présentation

`PDF OCR Translator` est une application **Flutter Linux desktop** qui extrait du texte depuis des PDFs image via **OCR**, le traduit en utilisant un **graphe de pivots linguistiques**, et génère un PDF de sortie avec le texte traduit superposé sur chaque page. **Tout le traitement se fait localement** sur l'appareil — aucune donnée n'est envoyée vers un serveur tiers.

---

## Fonctionnalités

- **Extraction OCR** depuis des pages PDF image (PaddleOCR PP-OCRv4 via ONNX Runtime)
- **Détection automatique de la langue source** page par page (FastText LID 176 langues + analyse Unicode)
- **Confirmation et personnalisation** par page avant traduction
- **Traduction hors-ligne** vers 16 langues via **graphe de pivots** (Opus-MT + CTranslate2)
- **Génération d'un PDF de sortie** avec textes en surimpression
- Choix du chemin et nom du fichier de sortie avant le lancement
- Indicateur de progression détaillé par page et par étape
- Mode debug : images intermédiaires et logs exportés dans un répertoire configurable

---

## Architecture du Graphe de Pivots

Le système de traduction utilise une **architecture en étoile** centrée sur l'anglais (en) :

```
     ┌─────────────┐
     │   Source    │
     └──────┬──────┘
            │
     ┌──────▼──────┐
     │   Anglais    │◄─────── Pivot Central
     │    (en)      │
     └──────┬──────┘
            │
     ┌──────▼──────┐
     │   Cible     │
     └─────────────┘
```

### Pivots Entrants (Source → Anglais)

| Modèle | Langues | Source HuggingFace |
|--------|---------|-------------------|
| `ja-en` | Japonais → Anglais | Helsinki-NLP/opus-mt-ja-en |
| `zh-en` | Chinois → Anglais | Helsinki-NLP/opus-mt-zh-en |
| `ko-en` | Coréen → Anglais | Helsinki-NLP/opus-mt-ko-en |
| `ru-en` | Russe → Anglais | Helsinki-NLP/opus-mt-ru-en |
| `ar-en` | Arabe → Anglais | Helsinki-NLP/opus-mt-ar-en |
| `hi-en` | Hindi → Anglais | Helsinki-NLP/opus-mt-hi-en |
| `th-en` | Thaï → Anglais | Helsinki-NLP/opus-mt-th-en |
| `vi-en` | Vietnamien → Anglais | Helsinki-NLP/opus-mt-vi-en |
| `de-en` | Allemand → Anglais | Helsinki-NLP/opus-mt-de-en |
| `nl-en` | Néerlandais → Anglais | Helsinki-NLP/opus-mt-nl-en |
| `pl-en` | Polonais → Anglais | Helsinki-NLP/opus-mt-pl-en |
| `ROMANCE-en` | Français/Espagnol/Italien/Portugais → Anglais | Helsinki-NLP/opus-mt-ROMANCE-en |

### Pivots Sortants (Anglais → Cible)

| Modèle | Langues | Source HuggingFace |
|--------|---------|-------------------|
| `en-ROMANCE` | Anglais → Français/Espagnol/Italien/Portugais | Helsinki-NLP/opus-mt-en-ROMANCE |
| `en-zh` | Anglais → Chinois | Helsinki-NLP/opus-mt-en-zh |
| `en-de` | Anglais → Allemand | Helsinki-NLP/opus-mt-en-de |
| `en-nl` | Anglais → Néerlandais | Helsinki-NLP/opus-mt-en-nl |
| `en-ru` | Anglais → Russe | Helsinki-NLP/opus-mt-en-ru |
| `en-hi` | Anglais → Hindi | Helsinki-NLP/opus-mt-en-hi |
| `en-ar` | Anglais → Arabe | argostranslate/argos-opus-en-ar (TC-Big) |
| `en-vi` | Anglais → Vietnamien | Helsinki-NLP/opus-mt-en-vi |
| `en-mul` | Anglais → Japonais/Thaï | Helsinki-NLP/opus-mt-en-mul |
| `tc-big-en-ko` | Anglais → Coréen | argostranslate/argos-opus-en-ko (TC-Big) |
| `en-sla` | Anglais → Polonais | Helsinki-NLP/opus-mt-en-sla |

### Routage Automatique

Pour traduire de la langue A vers la langue B :

1. **Traduction directe** si le modèle `A-B` existe
2. **Pivot via l'anglais** si `A→en` et `en→B` existent : `A → en → B`
3. **Échec** : retourne le texte original si aucune route disponible

Exemple : `fr → de` = `fr→en` (ROMANCE-en) + `en→de` (en-de)

---

## État d'implémentation

| Fonctionnalité | Statut | Notes |
|---|---|---|
| Sélection du PDF source | ✅ Implémenté | Via `file_picker` |
| Choix du fichier de sortie | ✅ Implémenté | Dialog pré-rempli, bouton "Parcourir…" |
| Rendu des pages en images | ✅ Implémenté | `pdftoppm` à 150 DPI (détection) / 600 DPI (OCR) |
| OCR | ✅ Implémenté | PaddleOCR PP-OCRv4 via ONNX Runtime, subprocess Python |
| Détection de langue | ✅ Implémenté | 3 passes PaddleOCR + FastText LID 176 langues |
| **Traduction** | ✅ Implémenté | **Opus-MT (Helsinki-NLP), CTranslate2 + sentencepiece, 100 % hors-ligne** |
| **Modèles de traduction** | ✅ **Graphe de pivots** | 22 modèles OPUS-MT, ~50 MB par paire |
| Confirmation des langues | ✅ Implémenté | Écran de validation page par page avec miniature zoomable |
| Génération PDF par page | ✅ Implémenté | `compute()` Flutter — isolate de fond |
| Assemblage du document final | ✅ Implémenté | `pdfunite` (poppler-utils) |
| Progression détaillée | ✅ Implémenté | Cercle global + barre d'étape |
| Cache de traduction | ✅ Implémenté | Cache persistant par paire de langues |
| Build Linux desktop | ✅ Fonctionnel | `flutter_app/build/linux/x64/release/bundle/` |
| Packaging Snap | ✅ Fonctionnel | Python env, PaddleOCR, CTranslate2 et poppler-utils bundlés |

---

## Architecture Globale

```
PDF source (sélectionné par l'utilisateur)
   │
   ├─ pdfinfo              → nombre de pages
   │
   └─ Phase 1 — Détection de langue (par page) :
        ├─ pdftoppm 150DPI → image PNG (miniature)
        └─ paddle_runner.py → 3 passes (ch → japan → en) + analyse Unicode
           └─ fasttext_detect.py → classification FastText LID si script latin
   │
   └─ Écran de confirmation — résumé par page, personnalisation optionnelle
   │
   └─ Phase 2 — Traduction (par page) :
        ├─ pdftoppm 600DPI → image PNG haute résolution
        ├─ paddle_runner.py → blocs texte + bounding boxes
        ├─ opusmt_translate.py → Opus-MT (CTranslate2 + sentencepiece)
        │   └─ Graphe de pivots : routage automatique via anglais
        └─ compute() → PDF de la page (isolate de fond)
                                  │
                                  └─ fichier PDF temporaire
   │
   └─ pdfunite             → assemblage en fichier de destination
```

---

## Composants Techniques

### Outils Système Requis

| Outil | Paquet apt | Usage |
|---|---|---|
| `pdfinfo` | `poppler-utils` | Comptage des pages |
| `pdftoppm` | `poppler-utils` | Rendu page → PNG (150/600 DPI) |
| `pdfunite` | `poppler-utils` | Assemblage PDF final |
| `curl` | `curl` | Téléchargement des modèles OPUS-MT depuis HuggingFace |

### Scripts Python Bundlés (`assets/scripts/`)

| Script | Rôle |
|--------|------|
| `paddle_runner.py` | Extraction OCR et détection de script via RapidOCR (ONNX Runtime) |
| `fasttext_detect.py` | Classification de langue via FastText LID (`lid.176.ftz`) |
| `opusmt_translate.py` | Traduction par lot via Opus-MT / CTranslate2 |

### Packages Flutter Actifs

| Package | Version | Usage |
|---|---|---|
| `go_router` | `^17.0.0` | Navigation |
| `file_picker` | `^11.0.0` | Sélection du PDF source et du fichier de sortie |
| `pdf` | `^3.10.0` | Génération PDF par page avec overlay |
| `image` | `^4.1.0` | Décodage PNG pour calcul dimensions |
| `path_provider` | `^2.1.0` | Chemins système |
| `path` | `^1.8.3` | Manipulation de chemins |
| `logger` | `^2.0.0` | Logging |
| `permission_handler` | `^12.0.0` | Permissions fichiers |

### Packages Python (Bundlés dans le Snap)

| Package | Version | Usage |
|---|---|---|
| `rapidocr-onnxruntime` | Latest | OCR PaddleOCR via ONNX Runtime (compatible AVX, sans AVX2) |
| `onnxruntime` | Latest | Moteur ONNX — inférence rapide |
| `opencv-python` | Latest | Traitement d'image pour RapidOCR |
| `ctranslate2` | Latest | **Inférence Opus-MT rapide sur CPU** |
| `sentencepiece` | Latest | **Tokenisation pour Opus-MT** |
| `fasttext-wheel` | Latest | Classification de langue FastText LID (176 langues) |

---

## Structure du Projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart                           # Bootstrap, GoRouter, pré-chargement
│   │   ├── screens/
│   │   │   ├── home_screen.dart                # Sélection PDF + langue cible + dialog sortie
│   │   │   ├── processing_screen.dart          # Détection langue → confirmation → traduction
│   │   │   └── result_screen.dart              # Affichage du fichier produit
│   │   ├── services/
│   │   │   ├── pdf_service.dart                # Pipeline complet (pdfinfo/pdftoppm/pdfunite/compute)
│   │   │   ├── ocr_service.dart                # RapidOCR + FastText LID — détection et OCR
│   │   │   └── translation_service.dart        # **Opus-MT + Graphe de pivots — traduction**
│   │   ├── models/
│   │   │   ├── language.dart                   # 16 langues supportées
│   │   │   ├── language_detection.dart         # PageLanguage (code détecté, surcharge, miniature)
│   │   │   ├── processing.dart                 # ProcessingUpdate (progression)
│   │   │   └── app_logger.dart                 # Logger + répertoire debug
│   │   └── theme/
│   │       └── app_theme.dart
│   ├── assets/
│   │   ├── fonts/                              # Roboto Regular/Bold/Italic
│   │   ├── models/
│   │   │   ├── lid.176.ftz                    # FastText LID, ~900 KB
│   │   │   └── onnx/                          # Modèles ONNX pour RapidOCR
│   │   │       ├── ch_det.onnx
│   │   │       ├── ch_rec.onnx
│   │   │       ├── japan_rec.onnx
│   │   │       ├── korean_rec.onnx
│   │   │       ├── arabic_rec.onnx
│   │   │       ├── cyrillic_rec.onnx
│   │   │       ├── devanagari_rec.onnx
│   │   │       └── thai_rec.onnx
│   │   ├── translation_models/                # **Modèles OPUS-MT (graphe de pivots)**
│   │   │   ├── ja-en/
│   │   │   ├── zh-en/
│   │   │   ├── ROMANCE-en/
│   │   │   ├── en-ROMANCE/
│   │   │   ├── tc-big-en-ar/
│   │   │   └── ... (22 modèles au total)
│   │   └── scripts/
│   │       ├── paddle_runner.py
│   │       ├── fasttext_detect.py
│   │       └── opusmt_translate.py
│   ├── linux/
│   └── pubspec.yaml
├── scripts/
│   ├── download_fasttext_model.sh       # Télécharge lid.176.ftz
│   ├── download_pip_wheels.sh           # Télécharge les wheels Python pour le snap
│   └── prepare_translation_models.sh     # **Télécharge et convertit les modèles OPUS-MT**
├── snapcraft.yaml                       # Snap (core24, confinement strict)
├── build-snap.sh                        # Script de build complet
├── install-local.sh                     # Installation locale du snap
└── README.md
```

---

## Flux Utilisateur

1. **HomeScreen** — sélection du PDF source, choix de la langue cible, chemin de sortie
2. **Phase détection** — pour chaque page : miniature 150 DPI + détection automatique de langue
3. **Écran de confirmation** — liste des pages avec langue détectée et miniature zoomable ; option "Personnaliser" pour surcharger par page ou pour l'ensemble du document
4. **Phase traduction** — pour chaque page : OCR 600 DPI → Opus-MT (via graphe de pivots) → PDF de page (isolate)
5. **Assemblage** — `pdfunite` fusionne tous les PDFs de pages → fichier de destination
6. **ResultScreen** — chemin du fichier produit

---

## Langues Supportées

16 langues définies dans `language.dart` :

| Code | Langue | Script | Modèle OCR | Pivot Entrant | Pivot Sortant |
|------|--------|--------|-------------|---------------|---------------|
| `en` | English | Latin | ch | — | — |
| `fr` | Français | Latin | ch | ROMANCE-en | en-ROMANCE |
| `es` | Español | Latin | ch | ROMANCE-en | en-ROMANCE |
| `de` | Deutsch | Latin | ch | de-en | en-de |
| `it` | Italiano | Latin | ch | ROMANCE-en | en-ROMANCE |
| `pt` | Português | Latin | ch | ROMANCE-en | en-ROMANCE |
| `nl` | Nederlands | Latin | ch | nl-en | en-nl |
| `pl` | Polski | Latin | ch | pl-en | en-sla |
| `ru` | Русский | Cyrillique | cyrillic | ru-en | en-ru |
| `ja` | 日本語 | Japonais | japan | ja-en | en-mul |
| `zh` | 中文 | CJK | ch | zh-en | en-zh |
| `ko` | 한국어 | Hangul | korean | ko-en | tc-big-en-ko |
| `ar` | العربية | Arabe | arabic | ar-en | tc-big-en-ar |
| `hi` | हिन्दी | Devanagari | devanagari | hi-en | en-hi |
| `th` | ไทย | Thaï | thai | th-en | en-mul |
| `vi` | Tiếng Việt | Latin | ch | vi-en | en-vi |

> **Note** : Les modèles de traduction sont basés sur OPUS-MT (Helsinki-NLP) avec certains modèles TC-Big (argostranslate) pour une meilleure performance.

---

## Modèles de Traduction

### Organisation

Les modèles sont organisés en **graphe de pivots** :

```
Modèles Pivots Entrants (12) : Source → Anglais
├── Modèles dédiés : ja-en, zh-en, ko-en, ru-en, ar-en, hi-en, th-en, vi-en, de-en, nl-en, pl-en
└── Modèles groupés : ROMANCE-en (fr, es, it, pt)

Modèles Pivots Sortants (12) : Anglais → Cible
├── Modèles dédiés : en-de, en-nl, en-ru, en-hi, en-vi
├── Modèles groupés : en-ROMANCE (fr, es, it, pt)
├── Modèles multi-langues : en-mul (ja, th), en-sla (pl)
└── Modèles TC-Big : tc-big-en-ar, tc-big-en-ko
```

### Stockage

- **Format** : CTranslate2 (INT8 quantifié) pour performance optimale
- **Taille** : ~50 MB par paire de langues
- **Emplacement** : `flutter_app/assets/translation_models/`
- **Bundling** : Inclus dans le snap (taille totale ~1.1 GB)

### Préparation des Modèles

Pour générer les modèles localement :

```bash
# Rendre exécutable
chmod +x scripts/prepare_translation_models.sh

# Télécharger et convertir tous les modèles
./scripts/prepare_translation_models.sh

# Options disponibles
./scripts/prepare_translation_models.sh --list       # Liste les modèles sans télécharger
./scripts/prepare_translation_models.sh --small      # Télécharge 4 modèles pour test
./scripts/prepare_translation_models.sh --clean     # Nettoie avant téléchargement
./scripts/prepare_translation_models.sh --verbose    # Mode verbeux
```

**Prérequis** :
- `git` et `git-lfs` — pour télécharger depuis HuggingFace
- `python3.12+` et `pip` — pour la conversion CTranslate2
- `ctranslate2` — installé automatiquement si manquant

---

## Installation (Utilisateur Final)

Le snap est **autonome** : Python, PaddleOCR (ONNX Runtime), FastText, CTranslate2, sentencepiece et poppler-utils sont **bundlés**. Aucune dépendance à installer manuellement.

```bash
# Depuis le Snap Store (à venir)
sudo snap install pdf-ocr-translator
snap run pdf-ocr-translator

# Ou depuis un fichier local (développement)
sudo snap install --dangerous pdf-ocr-translator_0.1.0_amd64.snap
```

La connexion au content snap GTK3 (`gnome-46-2404`) est établie automatiquement par le Snap Store.

---

## Build Depuis les Sources

### Ce dont tu as besoin sur ta machine

| Outil | Installation | Rôle |
|---|---|---|
| Flutter SDK | voir ci-dessous | Compiler l'application |
| `build-essential`, `cmake`, `ninja-build`, `clang`, `pkg-config`, `libgtk-3-dev` | `apt install` | Toolchain de build Flutter Linux |
| `libglycin-2-0` | `apt install` | Chargeur d'images GNOME 46 |
| Snapcraft | `snap install snapcraft --classic` | Packager le snap |
| `gnome-46-2404` | `snap install gnome-46-2404` | Content snap GTK3 (runtime + build) |

```bash
# Toolchain Flutter Linux (Ubuntu/Debian)
sudo apt update && sudo apt install \
  build-essential cmake ninja-build clang pkg-config libgtk-3-dev \
  libglycin-2-0

# Flutter SDK
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
flutter config --enable-linux-desktop

# Snapcraft
sudo snap install snapcraft --classic
sudo snap install gnome-46-2404
```

> **Pas besoin** d'installer Python, PaddleOCR, CTranslate2 ou poppler-utils : ils sont téléchargés et bundlés automatiquement dans le snap lors du build.

### Premier Build (après clonage)

```bash
# Installer les dépendances Flutter
cd flutter_app && flutter pub get && cd ..

# Lancer le build complet
bash build-snap.sh
```

`build-snap.sh` orchestre automatiquement :
1. ✅ Téléchargement du modèle FastText LID (`lid.176.ftz`, ~900 KB) si absent
2. ✅ Téléchargement des wheels Python si absentes (`rapidocr-onnxruntime`, `onnxruntime`, `opencv-python`, `ctranslate2`, `sentencepiece`, `fasttext-wheel` ~185 MB + dépendances)
3. ✅ Build Flutter Linux release (ignoré si les sources `.dart` n'ont pas changé)
4. ✅ Build snapcraft incrémental (seules les parties modifiées sont reconstruites)

> **Note** : Les modèles de traduction OPUS-MT sont téléchargés **au premier usage** par l'application. Pour les bundler dans le snap, exécutez d'abord `scripts/prepare_translation_models.sh`.

Le premier build prend **20–30 min** (téléchargements + compilation). Les suivants sont bien plus rapides.

### Builds Suivants

```bash
bash build-snap.sh          # build incrémental — ~3–5 min
bash build-snap.sh --clean  # rebuild complet depuis zéro — ~15 min
```

`--clean` est nécessaire uniquement après avoir modifié des `stage-packages` dans `snapcraft.yaml`. Si le fichier a changé sans `--clean`, le script affiche un avertissement.

### Installation et Test du Snap Produit (Développement)

```bash
bash install-local.sh
snap run pdf-ocr-translator
```

`install-local.sh` installe le snap et établit manuellement la connexion au content snap GTK3 (`gnome-46-2404`). Cette étape est nécessaire en local car l'installation avec `--dangerous` (fichier local) bypass le Snap Store, qui établit normalement cette connexion automatiquement. En production (Snap Store), aucune commande supplémentaire n'est requise.

### Mode Développement Flutter (sans snap)

Pour itérer rapidement sur l'interface sans passer par snapcraft :

```bash
# Prérequis supplémentaires (non nécessaires pour le build snap)
sudo apt install poppler-utils python3-pip
pip3 install rapidocr-onnxruntime onnxruntime opencv-python ctranslate2 sentencepiece fasttext-wheel

cd flutter_app
flutter run -d linux
```

---

## Dépendances Clés

### Outils Système (Bundlés dans le Snap)

| Outil | Paquet apt | Usage |
|---|---|---|
| `pdfinfo` | `poppler-utils` | Comptage des pages |
| `pdftoppm` | `poppler-utils` | Rendu page → PNG |
| `pdfunite` | `poppler-utils` | Assemblage PDF final |
| `curl` | `curl` | Téléchargement des modèles |

### Packages Python (Bundlés)

| Package | Usage |
|---|---|
| `rapidocr-onnxruntime` | OCR PaddleOCR via ONNX Runtime |
| `onnxruntime` | Moteur ONNX — inférence rapide |
| `opencv-python` | Traitement d'image pour RapidOCR |
| `ctranslate2` | **Inférence Opus-MT rapide sur CPU** |
| `sentencepiece` | **Tokenisation pour Opus-MT** |
| `fasttext-wheel` | Classification de langue FastText LID |

---

## Configuration du Graphe de Pivots

Le graphe de pivots est défini dans `translation_service.dart` :

```dart
static const _modelGraph = <String, (String, String?)>{
  // Pivots Entrants
  'fr-en': ('ROMANCE-en', null),
  'ja-en': ('ja-en', null),
  // ...
  
  // Pivots Sortants
  'en-fr': ('en-ROMANCE', '>>fr<<'),
  'en-ja': ('en-mul', '>>jpn<<'),
  // ...
}
```

Pour ajouter une nouvelle langue :
1. Ajouter le code langue dans `language.dart`
2. Définir les paires dans `_modelGraph`
3. Ajouter le modèle dans `scripts/prepare_translation_models.sh`
4. Mettre à jour `pubspec.yaml` avec le répertoire du modèle

---

## Bonnes Pratiques

### Gestion des Modèles

- **Ne pas commiter** les fichiers de modèles dans git (voir `.gitignore`)
- Utiliser `scripts/prepare_translation_models.sh` pour générer les modèles
- Les modèles sont téléchargés **au premier usage** si absents
- Pour le snap : bundler les modèles avec `prepare_translation_models.sh` avant le build

### Cache de Traduction

- Le cache est persistant dans `~/.config/pdf_ocr_translator/translation_cache.json`
- Utiliser `TranslationService().clearCache()` pour vider le cache
- Le cache utilise la clé `src→tgt:textHash` pour éviter les re-traductions

### Debug

- Activez le **mode debug** dans l'écran de confirmation pour :
  - Exporter les images intermédiaires dans `output/`
  - Générer des logs détaillés
  - Conserver les fichiers temporaires

---

## Limites Connues

| Limite | Statut | Solution |
|--------|--------|----------|
| Taille du snap avec tous les modèles | ~1.1 GB | Bundler seulement les modèles nécessaires |
| Téléchargement initial des modèles | Lent | Utiliser `prepare_translation_models.sh` avant le build |
| Traduction des langues rares | Non supporté | Ajouter les modèles OPUS-MT correspondants |
| OCR des textes manuscrits | Non supporté | PaddleOCR est optimisé pour texte imprimé |

---

## Roadmap

| Fonctionnalité | Priorité | Statut |
|---|---|---|
| Packaging Flatpak | Moyenne | ⏳ À faire |
| Support Windows | Moyenne | ⏳ À faire |
| Support macOS | Moyenne | ⏳ À faire |
| Traduction par lots (multiple PDFs) | Basse | ⏳ À faire |
| Sélection des pages à traiter | Moyenne | ⏳ À faire |
| Export en TXT/MD | Moyenne | ⏳ À faire |

---

## Licence

Apache License 2.0

## Contribuer

1. Fork du dépôt
2. Créer une branche : `git checkout -b feature/ma-fonctionnalite`
3. Commit : `git commit -m 'feat: description'`
4. Push : `git push origin feature/ma-fonctionnalite`
5. Créer une Pull Request

---

## Remerciements

- **PaddleOCR** : https://github.com/PaddlePaddle/PaddleOCR
- **ONNX Runtime** : https://onnxruntime.ai/
- **CTranslate2** : https://github.com/OpenNMT/CTranslate2
- **Opus-MT** : https://huggingface.co/Helsinki-NLP
- **FastText LID** : https://fasttext.cc/
- **RapidOCR** : https://github.com/RapidAI/RapidOCR
- **Flutter** : https://flutter.dev/

---

## Support

Pour les questions ou problèmes, ouvrez une issue sur GitHub ou contactez :
timothee.troncy@gmail.com
