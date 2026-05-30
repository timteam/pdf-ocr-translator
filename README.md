# PDF OCR Translator

Application Flutter Linux desktop qui traduit des PDFs image **entièrement hors-ligne** — aucune donnée ne quitte l'appareil.

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.16+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20Desktop-green.svg)

---

## Ce que ça fait

1. Tu sélectionnes un PDF (scanné, photo de document, etc.)
2. L'application détecte automatiquement la langue de chaque page
3. Tu confirmes (et surcharges si besoin) avant de lancer
4. L'OCR extrait chaque bloc de texte avec sa position
5. La traduction est appliquée hors-ligne via un graphe de modèles
6. Un nouveau PDF est généré avec le texte traduit superposé sur les pages originales

**Tout se passe localement.** Pas d'API, pas de clé, pas d'internet requis à l'exécution.

---

## Pipeline

```
PDF source
  │
  ├── pdfinfo ──────────────────────────── nombre de pages
  │
  ├── Phase 1 — Détection de langue
  │     pdftoppm 150 DPI → PNG
  │     paddle_runner.py (RapidOCR, 3 passes) + fasttext_detect.py
  │     → code langue BCP-47 par page
  │
  ├── Écran de confirmation
  │     miniatures + langues détectées, personnalisation optionnelle par page
  │
  ├── Phase 2 — Traduction
  │     pdftoppm 600 DPI → PNG
  │     paddle_runner.py → blocs texte + bounding boxes
  │     opusmt_translate.py → Opus-MT (CTranslate2) via graphe de pivots
  │     compute() → PDF de page (isolate Flutter)
  │
  └── pdfunite ─────────────────────────── PDF de sortie assemblé
```

---

## Graphe de pivots de traduction

La traduction passe toujours par l'anglais comme langue pivot centrale.

```
          Source
            │
       [source → en]   ← modèle pivot entrant
            │
        ANGLAIS
            │
        [en → cible]   ← modèle pivot sortant
            │
          Cible
```

**Exemple :** japonais → français = `ja-en` (opus-mt-ja-en) + `en-ROMANCE` (token `>>fr<<`)

### Modèles disponibles

| Direction | Modèle | Langues couvertes |
|-----------|--------|-------------------|
| **→ anglais** | `opus-mt-ja-en` | Japonais |
| | `opus-mt-zh-en` | Chinois |
| | `opus-mt-ko-en` | Coréen |
| | `opus-mt-ru-en` | Russe |
| | `opus-mt-ar-en` | Arabe |
| | `opus-mt-hi-en` | Hindi |
| | `opus-mt-th-en` | Thaï |
| | `opus-mt-vi-en` | Vietnamien |
| | `opus-mt-de-en` | Allemand |
| | `opus-mt-nl-en` | Néerlandais |
| | `opus-mt-pl-en` | Polonais |
| | `opus-mt-ROMANCE-en` | Français, Espagnol, Italien, Portugais |
| **anglais →** | `opus-mt-en-ROMANCE` | Français (`>>fr<<`), Espagnol (`>>es<<`), Italien (`>>it<<`), Portugais (`>>pt<<`) |
| | `opus-mt-en-de` | Allemand |
| | `opus-mt-en-nl` | Néerlandais |
| | `opus-mt-en-ru` | Russe |
| | `opus-mt-en-hi` | Hindi |
| | `opus-mt-en-zh` | Chinois (`>>cmn<<`) |
| | `opus-mt-en-vi` | Vietnamien (`>>vie<<`) |
| | `opus-mt-en-ar` | Arabe (`>>ara<<`) |
| | `opus-mt-en-mul` | Japonais (`>>jpn<<`), Thaï (`>>tha<<`) |
| | `opus-mt-en-sla` | Polonais (`>>pol<<`) |
| | `opus-mt-tc-big-en-ko` | Coréen |

Tous les modèles proviennent de [Helsinki-NLP](https://huggingface.co/Helsinki-NLP) et sont convertis au format CTranslate2 INT8 par `scripts/prepare_translation_models.sh`.

---

## Langues supportées

| Code | Langue | Script OCR | Pivot entrant | Pivot sortant |
|------|--------|-----------|---------------|---------------|
| `en` | English | ch (PP-OCRv4) | — | — |
| `fr` | Français | ch | ROMANCE-en | en-ROMANCE `>>fr<<` |
| `es` | Español | ch | ROMANCE-en | en-ROMANCE `>>es<<` |
| `de` | Deutsch | ch | de-en | en-de |
| `it` | Italiano | ch | ROMANCE-en | en-ROMANCE `>>it<<` |
| `pt` | Português | ch | ROMANCE-en | en-ROMANCE `>>pt<<` |
| `nl` | Nederlands | ch | nl-en | en-nl |
| `pl` | Polski | ch | pl-en | en-sla `>>pol<<` |
| `ru` | Русский | cyrillic (PP-OCRv5) | ru-en | en-ru |
| `ja` | 日本語 | japan (PP-OCRv1) | ja-en | en-mul `>>jpn<<` |
| `zh` | 中文 | ch | zh-en | en-zh `>>cmn<<` |
| `ko` | 한국어 | korean (PP-OCRv1) | ko-en | tc-big-en-ko |
| `ar` | العربية | arabic (PP-OCRv5) | ar-en | en-ar `>>ara<<` |
| `hi` | हिन्दी | devanagari (PP-OCRv5) | hi-en | en-hi |
| `th` | ไทย | thai (PP-OCRv5) | th-en | en-mul `>>tha<<` |
| `vi` | Tiếng Việt | ch | vi-en | en-vi `>>vie<<` |

---

## OCR — Préprocessing adaptatif

RapidOCR normalise en interne avec `(px/255 − 0.5) / 0.5` sur image BGR 3 canaux. Le préprocessing externe est donc **adaptatif et non-destructif** :

| Étape | Condition | Raison |
|-------|-----------|--------|
| CLAHE sur canal L (LAB) | std pixel < 45 | Améliore le contraste local sans toucher la couleur |
| Unsharp masking | Variance Laplacien < 150 | Renforce les bords pour DBNet |
| Aucun préprocessing | Image déjà nette | Évite d'introduire des artefacts inutiles |

**Ne jamais appliquer** : binarisation Otsu, conversion en niveaux de gris, deskew Python (le deskew Dart 3 passes ±85° est déjà appliqué en amont).

---

## Installation (utilisateur final)

Le snap est **autonome** : Python 3.12, RapidOCR, CTranslate2, sentencepiece, FastText et poppler-utils sont bundlés — aucune dépendance à installer.

```bash
# Snap Store (à venir)
sudo snap install pdf-ocr-translator

# Ou depuis un fichier local
sudo snap install --dangerous pdf-ocr-translator_0.1.0_amd64.snap
bash install-local.sh   # établit la connexion GTK3 (gnome-46-2404)
```

---

## Build depuis les sources

### Prérequis

```bash
# Toolchain Flutter Linux
sudo apt install build-essential cmake ninja-build clang pkg-config libgtk-3-dev libglycin-2-0

# Flutter SDK
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter config --enable-linux-desktop

# Snapcraft
sudo snap install snapcraft --classic
sudo snap install gnome-46-2404
```

Python, les wheels et poppler ne sont **pas** à installer sur la machine de build — ils sont téléchargés et bundlés automatiquement.

### Préparer les modèles de traduction (une fois)

```bash
# Télécharge les 24 modèles Helsinki-NLP et les convertit en CTranslate2 INT8
chmod +x scripts/prepare_translation_models.sh
./scripts/prepare_translation_models.sh

# Options utiles
./scripts/prepare_translation_models.sh --list              # liste sans télécharger
./scripts/prepare_translation_models.sh --small             # 4 modèles (test rapide)
./scripts/prepare_translation_models.sh --clean             # recommence de zéro
./scripts/prepare_translation_models.sh --hf-token hf_xxxx # avec token HuggingFace
```

Les modèles (~50 MB chacun) sont écrits dans `flutter_app/assets/translation_models/` et bundlés dans le snap au prochain build.

#### Token HuggingFace (recommandé)

Les modèles sont publics, mais un token évite le rate-limiting lors des 24 téléchargements. Crée un token **Read** sur [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

**`build-snap.sh` gère le token interactivement** au premier build et le met en cache dans `.hf_token` (gitignore, `chmod 600`) pour les builds suivants :

```
🔑 Token HuggingFace en cache : hf_pvjP****
   [Entrée] Réutiliser   [n] Nouveau   [s] Supprimer   [i] Ignorer
   >
```

Pour les builds non interactifs (CI/CD) :

| Méthode | |
|---------|--|
| Variable d'environnement | `HF_TOKEN=hf_xxxx bash build-snap.sh` |
| Argument direct au script | `./scripts/prepare_translation_models.sh --hf-token hf_xxxx` |

### Build

```bash
cd flutter_app && flutter pub get && cd ..
bash build-snap.sh          # ~20-30 min au premier build (téléchargements inclus)
bash build-snap.sh          # ~3-5 min ensuite (incrémental)
bash build-snap.sh --clean  # rebuild complet (~15 min)
```

`build-snap.sh` orchestre dans l'ordre :
1. Téléchargement du modèle FastText LID (`lid.176.ftz`, ~900 KB)
2. Téléchargement des wheels Python (~185 MB)
3. Vérification de la présence des modèles de traduction
4. `flutter build linux --release`
5. `snapcraft`

### Mode développement Flutter (sans snap)

```bash
sudo apt install poppler-utils
pip3 install rapidocr-onnxruntime onnxruntime opencv-python ctranslate2 sentencepiece fasttext-wheel
cd flutter_app && flutter run -d linux
```

---

## Structure du projet

```
pdf-ocr-translator/
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart                     # Bootstrap, GoRouter
│   │   ├── screens/
│   │   │   ├── home_screen.dart          # Sélection PDF, langue cible, chemin sortie
│   │   │   ├── processing_screen.dart    # Détection → confirmation → traduction
│   │   │   └── result_screen.dart        # Fichier produit
│   │   ├── services/
│   │   │   ├── pdf_service.dart          # Orchestration pdfinfo/pdftoppm/pdfunite
│   │   │   ├── ocr_service.dart          # RapidOCR + FastText + deskew
│   │   │   └── translation_service.dart  # Graphe de pivots Opus-MT
│   │   └── models/
│   │       ├── language.dart             # 16 langues supportées
│   │       ├── language_detection.dart   # PageLanguage (code, surcharge, miniature)
│   │       └── processing.dart           # ProcessingUpdate (progression)
│   └── assets/
│       ├── models/
│       │   ├── lid.176.ftz               # FastText LID (~900 KB)
│       │   └── onnx/                     # Modèles RapidOCR PP-OCR (ONNX)
│       │       ├── japan_rec.onnx        # PP-OCRv1, ja
│       │       ├── korean_rec.onnx       # PP-OCRv1, ko
│       │       ├── arabic_rec.onnx       # PP-OCRv5 mobile, ar
│       │       ├── cyrillic_rec.onnx     # PP-OCRv5 mobile, ru
│       │       ├── devanagari_rec.onnx   # PP-OCRv5 mobile, hi
│       │       └── thai_rec.onnx         # PP-OCRv5 mobile, th
│       ├── translation_models/           # Opus-MT CTranslate2 INT8 (généré par script)
│       │   ├── ja-en/                    # model.bin + source.spm + target.spm
│       │   ├── en-ROMANCE/
│       │   └── ...                       # 23 répertoires au total
│       └── scripts/
│           ├── paddle_runner.py          # OCR et détection de script
│           ├── fasttext_detect.py        # Classification de langue FastText
│           └── opusmt_translate.py       # Traduction par lot CTranslate2
├── scripts/
│   ├── download_fasttext_model.sh        # Télécharge lid.176.ftz
│   ├── download_pip_wheels.sh            # Télécharge les wheels Python
│   └── prepare_translation_models.sh    # Convertit les modèles Opus-MT → CTranslate2
├── snapcraft.yaml                        # Snap (core24, confinement strict)
├── build-snap.sh                         # Orchestration du build complet
└── install-local.sh                      # Installation + connexion GTK3
```

---

## Stack technique

| Couche | Technologie | Rôle |
|--------|-------------|------|
| UI | Flutter 3.16+, GoRouter | Interface Linux desktop |
| PDF | poppler-utils (`pdftoppm`, `pdfunite`) | Rendu et assemblage |
| OCR | RapidOCR 1.4.4 + ONNX Runtime 1.26 | PP-OCRv4/v5 via ONNX, compatible AVX (sans AVX2) |
| Détection langue | PP-OCRv4 (3 passes) + FastText LID 176 | Script Unicode → BCP-47 |
| Traduction | Opus-MT (Helsinki-NLP) + CTranslate2 + sentencepiece | 23 modèles INT8, graphe étoile via EN |
| Packaging | Snap (core24, confinement strict) | Autonome, sans dépendances système |

> **Pourquoi ONNX Runtime ?** PaddlePaddle 3.3.1 utilise des instructions AVX2 absentes sur les CPUs Ivy Bridge (2012). ONNX Runtime dispatche les instructions au runtime — AVX suffit.

---

## Limites connues

- **OCR manuscrit** : PP-OCRv4 est optimisé pour le texte imprimé
- **PDF vectoriel** : l'OCR n'est pas utile si le PDF contient déjà du texte sélectionnable
- **Mise en page complexe** : les bounding boxes texte sont superposées mais la police de substitution ne correspond pas toujours à l'original
- **Modèles de traduction** : doivent être générés avant le build snap (`prepare_translation_models.sh`) ; l'application ne les télécharge pas à l'exécution

---

## Licence

Apache License 2.0 — voir [LICENSE](LICENSE)

## Crédits

[RapidOCR](https://github.com/RapidAI/RapidOCR) · [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) · [ONNX Runtime](https://onnxruntime.ai) · [CTranslate2](https://github.com/OpenNMT/CTranslate2) · [Opus-MT / Helsinki-NLP](https://huggingface.co/Helsinki-NLP) · [FastText](https://fasttext.cc) · [Flutter](https://flutter.dev)

Issues et contributions : [github.com/AgentLeChat/pdf-ocr-translator](https://github.com/AgentLeChat/pdf-ocr-translator)
