#!/bin/bash
#
# Télécharge NLLB-200-distilled-600M (CTranslate2 INT8, pré-converti).
#
# Usage :
#   ./scripts/prepare_translation_models.sh [OPTIONS]
#
# OPTIONS
#   -h, --help          Cette aide
#   --clean             Re-télécharge même si model.bin existe déjà
#   --hf-token TOKEN    Token HuggingFace (recommandé pour éviter le rate-limiting)
#
# WORKFLOW
#   1. Installe huggingface_hub + hf-transfer (~quelques Mo, quelques secondes)
#   2. Télécharge michaelfeil/ct2fast-nllb-200-distilled-600M (~500 Mo)
#      (modèle CTranslate2 INT8 pré-converti — aucune dépendance torch/transformers)
#   3. Place le résultat dans assets/translation_models/nllb-200-distilled-600M/
#
# DEST_DIR : flutter_app/assets/translation_models/ (non modifiable, fixé par pubspec)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../flutter_app/assets/translation_models"
CACHE_BASE="$SCRIPT_DIR/../.ct2_cache"
PKGS_DIR="$CACHE_BASE/pkgs"
PIP_CACHE_DIR="$CACHE_BASE/pip"
PKGS_HASH_FILE="$CACHE_BASE/pkgs.hash"
HF_TOKEN_CACHE="$SCRIPT_DIR/../.hf_token"
PIP_PYZ=""

MODEL_KEY="nllb-200-distilled-600M"
# Modèle CTranslate2 INT8 pré-converti — évite torch + transformers
MODEL_HF="Serkan007/CTranslate2-nllb-200-int8"

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Télécharge NLLB-200-distilled-600M (CTranslate2 INT8, pré-converti).

OPTIONS
  -h, --help          Cette aide
  --clean             Re-télécharge même si model.bin existe déjà
  --hf-token TOKEN    Token HuggingFace (évite le rate-limiting)

MODÈLE
  Source  : $MODEL_HF (~500 Mo)
  Sortie  : $DEST_DIR/$MODEL_KEY/

TOKEN HUGGINGFACE
  Priorité : --hf-token > .hf_token > \$HF_TOKEN > huggingface-cli login
  Créer un token Read sur https://huggingface.co/settings/tokens

EXEMPLES
  $0                              # Téléchargement direct
  $0 --clean                      # Forcer le re-téléchargement
  $0 --hf-token hf_xxxx           # Avec token HF
EOF
}

# ─── Installation minimale : huggingface_hub + hf-transfer ───────────────────
_pkgs_hash() {
  local py_ver
  py_ver=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null || echo "?")
  printf '%s\n' "py=${py_ver}" "huggingface_hub>=0.20" "hf-transfer" \
    | md5sum | cut -d' ' -f1
}

setup_packages() {
  mkdir -p "$PKGS_DIR" "$PIP_CACHE_DIR"
  local current_hash; current_hash=$(_pkgs_hash)

  if [[ "$CLEAN" == false && -f "$PKGS_HASH_FILE" \
        && "$(cat "$PKGS_HASH_FILE")" == "$current_hash" ]]; then
    if PYTHONPATH="$PKGS_DIR" python3 -c "import huggingface_hub" 2>/dev/null; then
      local hfhub_ver
      hfhub_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c \
        "import huggingface_hub; print(huggingface_hub.__version__)" 2>/dev/null || echo "?")
      echo "→ huggingface_hub $hfhub_ver (cache)"
      return 0
    fi
    echo "→ Cache invalide — réinstallation…"
    rm -f "$PKGS_HASH_FILE"
  fi

  if [[ "$CLEAN" == true ]]; then
    echo "→ --clean : invalidation du cache packages"
    rm -rf "$PKGS_DIR" && mkdir -p "$PKGS_DIR"
    rm -f "$PKGS_HASH_FILE"
  fi

  PIP_PYZ=$(mktemp /tmp/pip_XXXXXXXX.pyz)
  echo "→ Téléchargement pip bootstrap…"
  curl -fL --progress-bar "https://bootstrap.pypa.io/pip/pip.pyz" -o "$PIP_PYZ"
  echo ""

  echo "→ Installation huggingface_hub + hf-transfer…"
  python3 "$PIP_PYZ" install \
    "huggingface_hub>=0.20" \
    hf-transfer \
    --target "$PKGS_DIR" \
    --cache-dir "$PIP_CACHE_DIR" \
    --quiet

  local hfhub_ver
  hfhub_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c \
    "import huggingface_hub; print(huggingface_hub.__version__)" 2>/dev/null || echo "")
  if [[ -z "$hfhub_ver" ]]; then
    echo "❌ Import huggingface_hub échoué"
    exit 1
  fi
  echo "→ huggingface_hub $hfhub_ver prêt"
  echo "$current_hash" > "$PKGS_HASH_FILE"
  echo ""
}

cleanup_packages() {
  [[ -n "$PIP_PYZ" && -f "$PIP_PYZ" ]] && rm -f "$PIP_PYZ"
}
_on_interrupt() {
  echo ""; echo "⚠  Interruption — arrêt."
  echo "   Relancez pour reprendre (model.bin absent = re-téléchargement)."
  exit 130
}
trap cleanup_packages EXIT
trap _on_interrupt INT TERM

# ─── Téléchargement du modèle pré-converti ───────────────────────────────────
_download_model() {
  local hf_id="$1" dest="$2"
  echo "  Téléchargement $hf_id (~500 Mo)…"
  _HF_ID="$hf_id" _DEST="$dest" \
  PYTHONPATH="$PKGS_DIR" HF_XET_HIGH_PERFORMANCE=1 \
  python3 - <<'PYEOF'
import os
from huggingface_hub import snapshot_download
# Seuls les fichiers nécessaires à CTranslate2 + nllb_translate.py
snapshot_download(
    repo_id=os.environ["_HF_ID"],
    local_dir=os.environ["_DEST"],
    repo_type="model",
    token=os.environ.get("HF_TOKEN") or None,
    allow_patterns=[
        "model.bin",
        "sentencepiece.bpe.model",
        "shared_vocabulary.json",
        "config.json",
    ],
)
PYEOF
}

# ─── Arguments ────────────────────────────────────────────────────────────────
CLEAN=false
HF_TOKEN_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --clean)     CLEAN=true; shift ;;
    --hf-token)
      [[ -z "${2:-}" ]] && { echo "❌ --hf-token requiert un TOKEN"; exit 1; }
      HF_TOKEN_ARG="$2"; shift 2 ;;
    *) echo "❌ Option inconnue : $1"; usage; exit 1 ;;
  esac
done

# ─── Token HuggingFace ────────────────────────────────────────────────────────
if [[ -n "$HF_TOKEN_ARG" ]]; then
  export HF_TOKEN="$HF_TOKEN_ARG"
  echo "→ Token HF : --hf-token"
elif [[ -f "$HF_TOKEN_CACHE" ]]; then
  export HF_TOKEN="$(< "$HF_TOKEN_CACHE")"
  echo "→ Token HF : .hf_token"
elif [[ -n "${HF_TOKEN:-}" ]]; then
  echo "→ Token HF : \$HF_TOKEN"
elif [[ -f "$HOME/.cache/huggingface/token" ]]; then
  export HF_TOKEN="$(< "$HOME/.cache/huggingface/token")"
  echo "→ Token HF : ~/.cache/huggingface/token"
else
  echo "ℹ  Aucun token HF (recommandé : --hf-token hf_xxx)"
fi
echo ""

# ─── Vérification pré-existante ───────────────────────────────────────────────
OUT_DIR="$DEST_DIR/$MODEL_KEY"

if [[ "$CLEAN" == false && -f "$OUT_DIR/model.bin" ]]; then
  size=$(du -sh "$OUT_DIR/model.bin" | cut -f1)
  echo "✅ $MODEL_KEY déjà présent ($size) — rien à faire."
  echo "   Utilisez --clean pour forcer le re-téléchargement."
  exit 0
fi

echo "Téléchargement de $MODEL_KEY"
echo "  Source  : $MODEL_HF"
echo "  Sortie  : $OUT_DIR"
echo ""

# ─── Packages ─────────────────────────────────────────────────────────────────
setup_packages

# ─── Téléchargement ───────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR" && touch "$OUT_DIR/.gitkeep"

if ! _download_model "$MODEL_HF" "$OUT_DIR"; then
  echo "❌ Téléchargement échoué"
  exit 1
fi

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [[ -f "$OUT_DIR/model.bin" && -f "$OUT_DIR/sentencepiece.bpe.model" ]]; then
  size=$(du -sh "$OUT_DIR" | cut -f1)
  echo "✅ $MODEL_KEY téléchargé ($size)"
  echo "   Fichiers : $(ls "$OUT_DIR" | grep -v '^\.' | tr '\n' ' ')"
else
  echo "❌ Téléchargement incomplet : fichiers manquants dans $OUT_DIR"
  ls -la "$OUT_DIR" || true
  exit 1
fi
