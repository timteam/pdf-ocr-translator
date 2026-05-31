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
  │     nllb_translate.py → NLLB-200-distilled-600M (CTranslate2) traduction directe
  │     compute() → PDF de page (isolate Flutter)
  │
  └── pdfunite ─────────────────────────── PDF de sortie assemblé
```

---

## Modèle de traduction

L'application utilise **[NLLB-200-distilled-600M](https://huggingface.co/facebook/nllb-200-distilled-600M)** de Meta AI :

- **200 langues** — traduction directe sans pivot intermédiaire (ex : japonais → français en une seule passe)
- **Format CTranslate2 INT8** — ~500 MB, inférence CPU optimisée
- **Un seul modèle** remplace l'ancien graphe de 24 modèles Opus-MT

```
   Source ──[NLLB-200]──▶ Cible
```

### Codes de langue

| Langue | Code interne | Code NLLB |
|--------|---|---|
| Anglais | `en` | `eng_Latn` |
| Français | `fr` | `fra_Latn` |
| Espagnol | `es` | `spa_Latn` |
| Allemand | `de` | `deu_Latn` |
| Italien | `it` | `ita_Latn` |
| Portugais | `pt` | `por_Latn` |
| Néerlandais | `nl` | `nld_Latn` |
| Polonais | `pl` | `pol_Latn` |
| Russe | `ru` | `rus_Cyrl` |
| Japonais | `ja` | `jpn_Jpan` |
| Chinois (simp.) | `zh` | `zho_Hans` |
| Coréen | `ko` | `kor_Hang` |
| Arabe | `ar` | `ara_Arab` |
| Hindi | `hi` | `hin_Deva` |
| Thaï | `th` | `tha_Thai` |
| Vietnamien | `vi` | `vie_Latn` |

---

## Langues supportées

| Code | Langue | Script OCR |
|------|--------|-----------|
| `en` | English | ch (PP-OCRv4) |
| `fr` | Français | ch |
| `es` | Español | ch |
| `de` | Deutsch | ch |
| `it` | Italiano | ch |
| `pt` | Português | ch |
| `nl` | Nederlands | ch |
| `pl` | Polski | ch |
| `ru` | Русский | cyrillic (PP-OCRv5) |
| `ja` | 日本語 | japan (PP-OCRv1) |
| `zh` | 中文 | ch |
| `ko` | 한국어 | korean (PP-OCRv1) |
| `ar` | العربية | arabic (PP-OCRv5) |
| `hi` | हिन्दी | devanagari (PP-OCRv5) |
| `th` | ไทย | thai (PP-OCRv5) |
| `vi` | Tiếng Việt | ch |

---

## OCR — Préprocessing adaptatif

RapidOCR normalise en interne avec `(px/255 − 0.5) / 0.5` sur image BGR 3 canaux. Le préprocessing externe est donc **adaptatif et non-destructif** :

| Étape | Condition | Raison |
|-------|-----------|--------|
| CLAHE sur canal L (LAB) | std pixel < 45 | Améliore le contraste local sans toucher la couleur |
| Unsharp masking | Variance Laplacien < 150 | Renforce les bords pour DBNet |
| Aucun préprocessing | Image déjà nette | Évite d'introduire des artefacts inutiles |

**Ne jamais appliquer** : binarisation Otsu, conversion en niveaux de gris, deskew Python (le deskew Dart 3 passes ±10° est déjà appliqué en amont).

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

### Modèle de traduction — deux modes de livraison

Le modèle **NLLB-200-distilled-600M** est téléchargé directement au format **CTranslate2 INT8 pré-converti** (~500 MB). Aucun torch ni transformers requis.

```
michaelfeil/ct2fast-nllb-200-distilled-600M (~500 Mo, CT2 INT8 pré-converti)
        │
  [prepare_translation_models.sh]   ← téléchargement direct, one-shot dev
        │
  ┌─────┴──────────────────────────────────┐
  │                                        │
  ▼                                        ▼
Bundlé dans le snap              Téléchargeable à la volée
flutter_app/assets/              depuis l'app (runtime)
translation_models/              → ~/.local/share/pdf-ocr-translator/
nllb-200-distilled-600M/           translation_models/
```

**Mode 1 — Bundlé dans le snap (build-time)**

```bash
chmod +x scripts/prepare_translation_models.sh
./scripts/prepare_translation_models.sh

# Avec token HuggingFace (recommandé)
./scripts/prepare_translation_models.sh --hf-token hf_xxxx

# Forcer le re-téléchargement
./scripts/prepare_translation_models.sh --clean
```

Le modèle (~500 MB) est écrit dans `flutter_app/assets/translation_models/nllb-200-distilled-600M/` et bundlé dans le snap au prochain build.

**Mode 2 — Téléchargement à la volée depuis l'app (runtime)**

L'app détecte si le modèle est manquant et propose de le télécharger directement depuis un dépôt HuggingFace Dataset. Le modèle est stocké dans `~/.local/share/pdf-ocr-translator/translation_models/` (prioritaire sur le modèle bundlé).

Pour activer ce mode, uploader le modèle converti une fois :

```bash
# 1. Convertir
./scripts/prepare_translation_models.sh --hf-token hf_...

# 2. Uploader vers le dépôt HF Dataset
./scripts/upload_models_to_hf.sh \
  --repo Timteamteem/nllb-ct2 \
  --hf-token hf_...

# 3. Vérifier la constante dans Flutter
#    flutter_app/lib/services/model_download_service.dart
#    → const String kModelHfRepo = 'Timteamteem/nllb-ct2';
```

#### Token HuggingFace (recommandé)

Le modèle `facebook/nllb-200-distilled-600M` est public mais un token évite le rate-limiting. Crée un token **Read** sur [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

**`build-snap.sh` gère le token interactivement** et le met en cache dans `.hf_token` (gitignore, `chmod 600`) :

```
🔑 Token HuggingFace en cache : hf_xxxx****
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
│   │   │   ├── translation_service.dart  # Graphe de pivots Opus-MT
│   │   │   └── model_download_service.dart # Téléchargement HTTP depuis HF Dataset
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
│       ├── translation_models/           # NLLB-200 CTranslate2 INT8 (généré par script)
│       │   └── nllb-200-distilled-600M/  # model.bin + sentencepiece.bpe.model
│       └── scripts/
│           ├── paddle_runner.py          # OCR et détection de script
│           ├── fasttext_detect.py        # Classification de langue FastText
│           └── nllb_translate.py         # Traduction par lot CTranslate2
├── scripts/
│   ├── download_fasttext_model.sh        # Télécharge lid.176.ftz
│   ├── download_pip_wheels.sh            # Télécharge les wheels Python
│   ├── prepare_translation_models.sh    # Télécharge et convertit NLLB → CTranslate2
│   └── upload_models_to_hf.sh           # Upload du modèle converti vers HF Dataset
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
| Traduction | NLLB-200-distilled-600M (Meta) + CTranslate2 + sentencepiece | 1 modèle INT8, 200 langues, traduction directe |
| Packaging | Snap (core24, confinement strict) | Autonome, sans dépendances système |

> **Pourquoi ONNX Runtime ?** PaddlePaddle 3.3.1 utilise des instructions AVX2 absentes sur les CPUs Ivy Bridge (2012). ONNX Runtime dispatche les instructions au runtime — AVX suffit.

---

## Limites connues

- **OCR manuscrit** : PP-OCRv4 est optimisé pour le texte imprimé
- **PDF vectoriel** : l'OCR n'est pas utile si le PDF contient déjà du texte sélectionnable
- **Mise en page complexe** : les bounding boxes texte sont superposées mais la police de substitution ne correspond pas toujours à l'original
- **Modèle de traduction** : NLLB-200-distilled-600M peut être bundlé dans le snap (build-time via `prepare_translation_models.sh`) ou téléchargé à la volée depuis l'app — le modèle doit avoir été uploadé sur le dépôt HF (`upload_models_to_hf.sh`) pour que le téléchargement runtime fonctionne

---

## Licence

Apache License 2.0 — voir [LICENSE](LICENSE)

## Crédits

[RapidOCR](https://github.com/RapidAI/RapidOCR) · [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) · [ONNX Runtime](https://onnxruntime.ai) · [CTranslate2](https://github.com/OpenNMT/CTranslate2) · [NLLB-200 / Meta AI](https://huggingface.co/facebook/nllb-200-distilled-600M) · [FastText](https://fasttext.cc) · [Flutter](https://flutter.dev)

Issues et contributions : [github.com/AgentLeChat/pdf-ocr-translator](https://github.com/AgentLeChat/pdf-ocr-translator)
