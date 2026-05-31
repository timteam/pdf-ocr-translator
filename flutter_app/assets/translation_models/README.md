# Translation Models Directory

Ce répertoire contient le modèle de traduction utilisé par `TranslationService`.

## Architecture

L'application utilise **NLLB-200-distilled-600M** (No Language Left Behind) de Meta :

- **200 langues** — traduction directe sans pivot intermédiaire
- **Format CTranslate2 INT8** — environ 500–600 MB sur disque
- **Un seul modèle** pour toutes les paires de langues supportées

```
Source (n'importe quelle langue)
        │
   [nllb-200-distilled-600M]
        │
 Cible (n'importe quelle langue)
```

## Codes de langue NLLB

| Code interne | Code NLLB | Langue |
|---|---|---|
| `en` | `eng_Latn` | Anglais |
| `fr` | `fra_Latn` | Français |
| `es` | `spa_Latn` | Espagnol |
| `de` | `deu_Latn` | Allemand |
| `it` | `ita_Latn` | Italien |
| `pt` | `por_Latn` | Portugais |
| `nl` | `nld_Latn` | Néerlandais |
| `pl` | `pol_Latn` | Polonais |
| `ru` | `rus_Cyrl` | Russe |
| `ja` | `jpn_Jpan` | Japonais |
| `zh` | `zho_Hans` | Chinois simplifié |
| `ko` | `kor_Hang` | Coréen |
| `ar` | `ara_Arab` | Arabe |
| `hi` | `hin_Deva` | Hindi |
| `th` | `tha_Thai` | Thaï |
| `vi` | `vie_Latn` | Vietnamien |

## Structure du répertoire

```
flutter_app/assets/translation_models/
└── nllb-200-distilled-600M/
    ├── model.bin                  # Modèle CTranslate2 INT8 (~500 MB, hors git)
    ├── sentencepiece.bpe.model    # Tokenizer SentencePiece
    ├── config.json
    └── .gitkeep
```

## Préparation du modèle

```bash
chmod +x scripts/prepare_translation_models.sh
./scripts/prepare_translation_models.sh

# Avec token HuggingFace (recommandé)
./scripts/prepare_translation_models.sh --hf-token hf_xxxx

# Forcer la reconversion
./scripts/prepare_translation_models.sh --clean
```

Le script télécharge `facebook/nllb-200-distilled-600M` (~1.2 GB) et le convertit
en CTranslate2 INT8 (~500 MB).

## Notes

- `model.bin` n'est **pas** versionné dans git (trop volumineux)
- `.gitkeep` marque le répertoire comme existant pour Flutter
- Les modèles peuvent être bundlés dans le snap ou téléchargés à la volée depuis l'app

## Voir aussi

- [TranslationService](../../lib/services/translation_service.dart)
- [prepare_translation_models.sh](../../../scripts/prepare_translation_models.sh)
- [nllb_translate.py](../scripts/nllb_translate.py)
