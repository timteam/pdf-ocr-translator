#!/bin/bash
#
# Upload des modèles CTranslate2 pré-convertis vers un dépôt HuggingFace Dataset.
#
# Ce script est une opération one-shot pour le développeur :
#   1. Convertir les modèles :  ./scripts/prepare_translation_models.sh
#   2. Uploader :               ./scripts/upload_models_to_hf.sh --repo OWNER/REPO --hf-token hf_...
#   3. Mettre à jour kModelHfRepo dans flutter_app/lib/services/model_download_service.dart
#
# L'app Flutter télécharge ensuite les modèles à la volée sans aucune conversion locale.
#
# Usage :
#   ./scripts/upload_models_to_hf.sh --repo OWNER/opus-mt-ct2 --hf-token hf_...
#   ./scripts/upload_models_to_hf.sh --repo OWNER/opus-mt-ct2 --models ja-en,en-ROMANCE
#
# Prérequis :
#   pip install huggingface_hub   (ou : pip3 install huggingface_hub)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/../flutter_app/assets/translation_models"
# Réutilise les packages installés par prepare_translation_models.sh
# (Python système = externally-managed sur Ubuntu 26.04, on n'y touche pas)
PKGS_DIR="$SCRIPT_DIR/../.ct2_cache/pkgs"

HF_REPO=""
HF_TOKEN=""
MODELS_FILTER=""
DRY_RUN=false

# ─── Arguments ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ -z "${2:-}" ]] && { echo "❌ --repo requiert OWNER/REPO"; exit 1; }
      HF_REPO="$2"; shift 2 ;;
    --hf-token)
      [[ -z "${2:-}" ]] && { echo "❌ --hf-token requiert TOKEN"; exit 1; }
      HF_TOKEN="$2"; shift 2 ;;
    --models)
      [[ -z "${2:-}" ]] && { echo "❌ --models requiert une liste de clés"; exit 1; }
      MODELS_FILTER="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      cat <<'EOF'
Upload des modèles CTranslate2 vers HuggingFace Dataset.

Usage: upload_models_to_hf.sh --repo OWNER/REPO [OPTIONS]

OPTIONS
  --repo OWNER/REPO   Dépôt HuggingFace Dataset (créé automatiquement si absent)
  --hf-token TOKEN    Token HuggingFace avec accès write
  --models KEY,...    Restreindre à certains modèles (ex: ja-en,en-ROMANCE)
  --dry-run           Lister les fichiers sans uploader
  -h, --help          Cette aide

WORKFLOW
  1. Convertir les modèles :
       ./scripts/prepare_translation_models.sh --small   # 4 modèles test
  2. Uploader :
       ./scripts/upload_models_to_hf.sh --repo timteam/opus-mt-ct2 --hf-token hf_xxx
  3. Mettre à jour la constante dans Flutter :
       flutter_app/lib/services/model_download_service.dart
       → const String kModelHfRepo = 'timteam/opus-mt-ct2';
EOF
      exit 0 ;;
    *)
      echo "❌ Option inconnue : $1"; exit 1 ;;
  esac
done

if [[ -z "$HF_REPO" ]]; then
  echo "❌ --repo OWNER/REPO requis."
  echo "   Exemple : $0 --repo timteam/opus-mt-ct2 --hf-token hf_..."
  exit 1
fi

# ─── Résolution du token ──────────────────────────────────────────────────────
if [[ -z "$HF_TOKEN" && -n "${HF_TOKEN_ENV:-}" ]]; then
  HF_TOKEN="$HF_TOKEN_ENV"
elif [[ -z "$HF_TOKEN" && -n "${HF_TOKEN:-}" ]]; then
  : # déjà défini via variable d'environnement
fi

if [[ -z "$HF_TOKEN" && -f "$HOME/.cache/huggingface/token" ]]; then
  HF_TOKEN="$(< "$HOME/.cache/huggingface/token")"
  echo "ℹ  Token HF lu depuis ~/.cache/huggingface/token"
fi

if [[ -z "$HF_TOKEN" ]]; then
  echo "⚠  Aucun token HuggingFace — tentative sans authentification."
  echo "   Pour les dépôts privés ou write : --hf-token hf_..."
fi

# ─── Vérification huggingface_hub ─────────────────────────────────────────────
if ! PYTHONPATH="$PKGS_DIR" python3 -c "import huggingface_hub" 2>/dev/null; then
  echo "❌ huggingface_hub non disponible dans .ct2_cache/pkgs."
  echo "   Exécutez d'abord : ./scripts/prepare_translation_models.sh --small"
  exit 1
fi

echo "📤 Upload vers HuggingFace Dataset : $HF_REPO"
echo "   Source : $MODELS_DIR"
[[ -n "$MODELS_FILTER" ]] && echo "   Filtre : $MODELS_FILTER"
$DRY_RUN && echo "   Mode : --dry-run (aucun upload)"
echo ""

# ─── Script Python d'upload ───────────────────────────────────────────────────
PYTHONPATH="$PKGS_DIR" python3 - <<PYEOF
import os, sys
from pathlib import Path
from huggingface_hub import HfApi, login

hf_token  = """$HF_TOKEN""".strip() or None
repo_id   = """$HF_REPO""".strip()
models_dir = Path("""$MODELS_DIR""")
filter_str = """$MODELS_FILTER""".strip()
dry_run    = """$DRY_RUN""" == "true"

# Authentification
if hf_token:
    login(token=hf_token, add_to_git_credential=False)

api = HfApi()

# Création du dépôt si besoin
if not dry_run:
    try:
        api.create_repo(
            repo_id=repo_id,
            repo_type="dataset",
            exist_ok=True,
            private=False,
        )
        print(f"  ✓ Dépôt Dataset '{repo_id}' prêt")
    except Exception as e:
        print(f"  ⚠  create_repo : {e}", file=sys.stderr)

# Sélection des modèles
models_filter = [k.strip() for k in filter_str.split(",") if k.strip()] if filter_str else None

model_dirs = sorted(
    d for d in models_dir.iterdir()
    if d.is_dir() and (models_filter is None or d.name in models_filter)
)

if not model_dirs:
    print("❌ Aucun modèle trouvé dans", models_dir, file=sys.stderr)
    sys.exit(1)

total_ok = 0
total_fail = 0

for model_path in model_dirs:
    model_bin = model_path / "model.bin"
    if not model_bin.exists():
        print(f"  ⏭  {model_path.name} — model.bin absent, ignoré")
        continue

    files = [f for f in model_path.iterdir() if f.is_file() and not f.name.startswith(".")]
    size_mb = sum(f.stat().st_size for f in files) / 1048576

    print(f"\n  [{model_path.name}]  {len(files)} fichiers  {size_mb:.0f} Mo")
    for f in files:
        kb = f.stat().st_size / 1024
        print(f"    {f.name}  ({kb:.0f} Ko)")

    if dry_run:
        continue

    try:
        for f in files:
            api.upload_file(
                path_or_fileobj=str(f),
                path_in_repo=f"{model_path.name}/{f.name}",
                repo_id=repo_id,
                repo_type="dataset",
            )
        print(f"  ✅ {model_path.name}")
        total_ok += 1
    except Exception as e:
        print(f"  ❌ {model_path.name} : {e}", file=sys.stderr)
        total_fail += 1

print()
if dry_run:
    print(f"✅ Dry-run terminé — {len(model_dirs)} modèle(s) à uploader")
else:
    print(f"✅ {total_ok} modèle(s) uploadé(s)" + (f", {total_fail} échec(s)" if total_fail else ""))
    print(f"\n   URL du dépôt : https://huggingface.co/datasets/{repo_id}")
    print(f"\n   ➡  Mettez à jour la constante dans Flutter :")
    print(f"      flutter_app/lib/services/model_download_service.dart")
    print(f"      → const String kModelHfRepo = '{repo_id}';")
PYEOF
