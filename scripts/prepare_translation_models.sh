#!/bin/bash
#
# Télécharge et convertit facebook/nllb-200-distilled-600M en CTranslate2 INT8.
#
# Usage :
#   ./scripts/prepare_translation_models.sh [OPTIONS]
#
# OPTIONS
#   -h, --help          Cette aide
#   --clean             Reconvertit même si model.bin existe déjà
#   --hf-token TOKEN    Token HuggingFace (recommandé pour éviter le rate-limiting)
#
# WORKFLOW
#   1. Installe ctranslate2, transformers, sentencepiece dans .ct2_cache/pkgs/
#   2. Télécharge facebook/nllb-200-distilled-600M via snapshot_download
#   3. Convertit en INT8 via convert_model.py
#   4. Place le résultat dans assets/translation_models/nllb-200-distilled-600M/
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
MODEL_HF="facebook/nllb-200-distilled-600M"

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Télécharge et convertit NLLB-200-distilled-600M en CTranslate2 INT8.

OPTIONS
  -h, --help          Cette aide
  --clean             Reconvertit même si model.bin existe déjà
  --hf-token TOKEN    Token HuggingFace (évite le rate-limiting)

MODÈLE
  Source  : $MODEL_HF
  Sortie  : $DEST_DIR/$MODEL_KEY/

TOKEN HUGGINGFACE
  Priorité : --hf-token > .hf_token > \$HF_TOKEN > huggingface-cli login
  Créer un token Read sur https://huggingface.co/settings/tokens

EXEMPLES
  $0                              # Téléchargement + conversion
  $0 --clean                      # Forcer la reconversion
  $0 --hf-token hf_xxxx           # Avec token HF
EOF
}

# ─── Packages de conversion ───────────────────────────────────────────────────
_pkgs_hash() {
  local py_ver
  py_ver=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null || echo "?")
  printf '%s\n' \
    "py=${py_ver}" \
    "ctranslate2" \
    "transformers>=4.40,<5.5" \
    "huggingface_hub>=0.20" \
    "sentencepiece" \
    "hf-transfer" \
    "torch-cpu" \
  | md5sum | cut -d' ' -f1
}

setup_packages() {
  mkdir -p "$PKGS_DIR" "$PIP_CACHE_DIR"
  local current_hash; current_hash=$(_pkgs_hash)

  if [[ "$CLEAN" == false && -f "$PKGS_HASH_FILE" \
        && "$(cat "$PKGS_HASH_FILE")" == "$current_hash" ]]; then
    if PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2, torch" 2>/dev/null; then
      local ct2_ver torch_ver
      ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "?")
      torch_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "?")
      echo "→ Packages en cache : ctranslate2 $ct2_ver / torch $torch_ver"
      echo "  (--clean pour forcer la réinstallation)"
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

  echo "→ Installation des packages (ctranslate2, transformers, hf-transfer…)"
  echo "  (~2-5 min à la première installation)"
  python3 "$PIP_PYZ" install \
    ctranslate2 \
    "transformers>=4.40,<5.5" \
    "huggingface_hub>=0.20" \
    sentencepiece \
    hf-transfer \
    --target "$PKGS_DIR" \
    --cache-dir "$PIP_CACHE_DIR"

  _install_torch || {
    echo "❌ Impossible d'installer torch."
    echo "   Workaround : sudo pip3 install torch --index-url https://download.pytorch.org/whl/cpu"
    exit 1
  }

  local ct2_ver torch_ver
  ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "")
  torch_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")

  if [[ -z "$ct2_ver" || -z "$torch_ver" ]]; then
    echo "❌ Import check échoué"
    PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2, torch" 2>&1 | head -5
    exit 1
  fi

  echo ""
  echo "→ ctranslate2 $ct2_ver / torch $torch_ver prêts"
  echo "$current_hash" > "$PKGS_HASH_FILE"
  echo ""
}

_install_torch() {
  if PYTHONPATH="$PKGS_DIR" python3 -c "import torch" 2>/dev/null; then
    echo "→ torch déjà disponible"
    return 0
  fi
  echo "→ Installation torch CPU (tentative 1/2 : PyTorch CDN ~200 MB)…"
  if python3 "$PIP_PYZ" install torch \
      --index-url https://download.pytorch.org/whl/cpu \
      --target "$PKGS_DIR" --cache-dir "$PIP_CACHE_DIR"; then
    return 0
  fi
  echo "⚠  CDN PyTorch inaccessible — tentative 2/2 : PyPI --no-deps…"
  python3 "$PIP_PYZ" install torch \
    --no-deps --target "$PKGS_DIR" --cache-dir "$PIP_CACHE_DIR"
}

cleanup_packages() {
  [[ -n "$PIP_PYZ" && -f "$PIP_PYZ" ]] && rm -f "$PIP_PYZ"
}
_on_interrupt() {
  echo ""; echo "⚠  Interruption — arrêt."
  echo "   Relancez pour reprendre (model.bin absent = reconversion)."
  exit 130
}
trap cleanup_packages EXIT
trap _on_interrupt INT TERM

# ─── Téléchargement du modèle ─────────────────────────────────────────────────
_download_model() {
  local hf_id="$1" dest="$2"
  echo "  Téléchargement $hf_id (~1.2 GB)…"
  _HF_ID="$hf_id" _DEST="$dest" \
  PYTHONPATH="$PKGS_DIR" HF_XET_HIGH_PERFORMANCE=1 \
  python3 - <<'PYEOF'
import os
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id=os.environ["_HF_ID"],
    local_dir=os.environ["_DEST"],
    repo_type="model",
    token=os.environ.get("HF_TOKEN") or None,
    ignore_patterns=["*.msgpack", "*.h5", "flax_model*", "tf_model*", "rust_model*", "*.ot"],
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
  echo "✅ $MODEL_KEY déjà converti ($size) — rien à faire."
  echo "   Utilisez --clean pour forcer la reconversion."
  exit 0
fi

echo "Conversion de $MODEL_KEY"
echo "  Source  : $MODEL_HF"
echo "  Sortie  : $OUT_DIR"
echo ""

# ─── Packages ─────────────────────────────────────────────────────────────────
setup_packages

# ─── Téléchargement + Conversion ─────────────────────────────────────────────
src_dir=$(mktemp -d)
echo "[1/2] Téléchargement…"
if ! _download_model "$MODEL_HF" "$src_dir"; then
  echo "❌ Téléchargement échoué"
  rm -rf "$src_dir"
  exit 1
fi

mkdir -p "$OUT_DIR" && touch "$OUT_DIR/.gitkeep"
echo ""
echo "[2/2] Conversion CTranslate2 INT8…"
PYTHONPATH="$PKGS_DIR" python3 "$SCRIPT_DIR/convert_model.py" "$src_dir" "$OUT_DIR"

rm -rf "$src_dir"

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [[ -f "$OUT_DIR/model.bin" ]]; then
  size=$(du -sh "$OUT_DIR" | cut -f1)
  echo "✅ $MODEL_KEY converti avec succès ($size)"
  echo "   Fichiers : $(ls "$OUT_DIR" | grep -v '^\.gitkeep$' | tr '\n' ' ')"
else
  echo "❌ Conversion échouée : model.bin absent dans $OUT_DIR"
  exit 1
fi
