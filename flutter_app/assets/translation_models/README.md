# Translation Models Directory

This directory contains the translation models for the pivot graph architecture used by `TranslationService`.

## Architecture

The translation system uses a **star-shaped pivot graph** centered on English (en):

```
Source → English → Target
```

### Incoming Pivots (Source → English)
- **Single language models**: ja-en, zh-en, ko-en, ru-en, ar-en, hi-en, th-en, vi-en, de-en, nl-en, pl-en
- **Family models**: ROMANCE-en (fr, es, it, pt → en)

### Outgoing Pivots (English → Target)
- **Family models**:
  - en-ROMANCE (en → fr, es, it, pt) with language tokens
  - en-mul (en → ja, th) with ISO 639-3 tokens
  - en-sla (en → pl, etc.) with language tokens
- **Single language models**: en-zh, en-de, en-nl, en-ru, en-hi
- **TC-Big models**: tc-big-en-ar, tc-big-en-ko

## Model Format

Models are stored in **CTranslate2 format** (INT8 quantized) for optimal performance.

Each model directory should contain:
- `model.bin` or `model.onnx` - The quantized model weights
- `vocab.*` - Vocabulary files
- `config.json` - Model configuration (optional)

## Model Preparation

To download and prepare all models, run:

```bash
chmod +x scripts/prepare_translation_models.sh
./scripts/prepare_translation_models.sh
```

### Options
- `--list` - List all available models without downloading
- `--small` - Download only a small subset for testing
- `--clean` - Remove existing models before downloading
- `-v, --verbose` - Enable verbose output

### Requirements
- `git` and `git-lfs` - For downloading models from HuggingFace
- `python3` and `pip` - For CTranslate2 conversion
- `ctranslate2` - Will be auto-installed if missing

## Directory Structure

```
flutter_app/assets/translation_models/
├── ja-en/           # Japanese → English
├── zh-en/           # Chinese → English
├── ko-en/           # Korean → English
├── ru-en/           # Russian → English
├── ar-en/           # Arabic → English
├── hi-en/           # Hindi → English
├── th-en/           # Thai → English
├── vi-en/           # Vietnamese → English
├── de-en/           # German → English
├── nl-en/           # Dutch → English
├── pl-en/           # Polish → English
├── ROMANCE-en/      # Romance languages → English
├── en-ROMANCE/      # English → Romance languages
├── en-zh/           # English → Chinese
├── en-de/           # English → German
├── en-nl/           # English → Dutch
├── en-ru/           # English → Russian
├── en-hi/           # English → Hindi
├── en-ar/           # English → Arabic
├── en-vi/           # English → Vietnamese
├── en-mul/          # English → Multiple (ja, th)
├── tc-big-en-ar/    # TC-Big English → Arabic
├── tc-big-en-ko/    # TC-Big English → Korean
└── en-sla/          # English → Slavic languages
```

## Notes

- These directories are **placeholders** and should be populated with actual model files
- The `.gitignore` file excludes these directories to avoid committing large model files
- Models are bundled with the snap package at build time
- For development, use `scripts/prepare_translation_models.sh` to generate models

## See Also
- [TranslationService](lib/services/translation_service.dart) - The main translation service
- [prepare_translation_models.sh](scripts/prepare_translation_models.sh) - Model preparation script
