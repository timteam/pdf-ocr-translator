#!/bin/bash
#
# Télécharge et convertit les modèles Helsinki-NLP opus-mt en CTranslate2 INT8.
#
# Usage :
#   ./scripts/prepare_translation_models.sh [OPTIONS]
#
# OPTIONS
#   -h, --help                 Cette aide
#   -l, --list                 Liste les modèles sans télécharger
#   -s, --small                4 modèles seulement (test rapide)
#   --clean                    Reconvertit même si model.bin existe déjà
#   --models KEY[,KEY...]      Sélectionner des modèles spécifiques
#   --hf-token TOKEN           Token HuggingFace (optionnel mais recommandé)
#
# WORKFLOW
#   1. Installe ctranslate2 + torch + transformers dans .ct2_cache/pkgs/
#   2. Pour chaque modèle : télécharge via snapshot_download (hf_transfer),
#      convertit en INT8 via convert_model.py, place dans assets/translation_models/
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

# ─── Graphe de modèles ────────────────────────────────────────────────────────
declare -A MODEL_HF=(
  ["ja-en"]="Helsinki-NLP/opus-mt-ja-en"
  ["zh-en"]="Helsinki-NLP/opus-mt-zh-en"
  ["ko-en"]="Helsinki-NLP/opus-mt-ko-en"
  ["ru-en"]="Helsinki-NLP/opus-mt-ru-en"
  ["ar-en"]="Helsinki-NLP/opus-mt-ar-en"
  ["hi-en"]="Helsinki-NLP/opus-mt-hi-en"
  ["th-en"]="Helsinki-NLP/opus-mt-th-en"
  ["vi-en"]="Helsinki-NLP/opus-mt-vi-en"
  ["de-en"]="Helsinki-NLP/opus-mt-de-en"
  ["nl-en"]="Helsinki-NLP/opus-mt-nl-en"
  ["pl-en"]="Helsinki-NLP/opus-mt-pl-en"
  ["ROMANCE-en"]="Helsinki-NLP/opus-mt-ROMANCE-en"
  ["en-ROMANCE"]="Helsinki-NLP/opus-mt-en-ROMANCE"
  ["en-de"]="Helsinki-NLP/opus-mt-en-de"
  ["en-nl"]="Helsinki-NLP/opus-mt-en-nl"
  ["en-ru"]="Helsinki-NLP/opus-mt-en-ru"
  ["en-hi"]="Helsinki-NLP/opus-mt-en-hi"
  ["en-zh"]="Helsinki-NLP/opus-mt-en-zh"
  ["en-ar"]="Helsinki-NLP/opus-mt-en-ar"
  ["en-vi"]="Helsinki-NLP/opus-mt-en-vi"
  ["en-mul"]="Helsinki-NLP/opus-mt-en-mul"
  ["en-sla"]="Helsinki-NLP/opus-mt-en-sla"
  ["tc-big-en-ar"]="Helsinki-NLP/opus-mt-tc-big-en-ar"
  ["tc-big-en-ko"]="Helsinki-NLP/opus-mt-tc-big-en-ko"
)

ALL_MODELS=(
  "ja-en" "zh-en" "ko-en" "ru-en" "ar-en" "hi-en" "th-en" "vi-en"
  "de-en" "nl-en" "pl-en" "ROMANCE-en"
  "en-ROMANCE" "en-de" "en-nl" "en-ru" "en-hi" "en-zh" "en-ar"
  "en-vi" "en-mul" "en-sla" "tc-big-en-ar" "tc-big-en-ko"
)

SMALL_MODELS=("ja-en" "ROMANCE-en" "en-ROMANCE" "en-de")

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Convertit les modèles Helsinki-NLP opus-mt en CTranslate2 INT8.

OPTIONS
  -h, --help             Cette aide
  -l, --list             Liste les modèles sans télécharger
  -s, --small            4 modèles seulement (ja-en, ROMANCE-en, en-ROMANCE, en-de)
  --clean                Reconvertit même si model.bin existe déjà
  --models KEY[,KEY...]  Modèles spécifiques (ex: --models ja-en,en-ROMANCE)
  --hf-token TOKEN       Token HuggingFace (évite le rate-limiting)

TOKEN HUGGINGFACE
  Priorité : --hf-token > .hf_token > \$HF_TOKEN > huggingface-cli login
  Créer un token Read sur https://huggingface.co/settings/tokens

EXEMPLES
  $0                                  # Tout convertir
  $0 --small                          # Test rapide (4 modèles)
  $0 --models ja-en,en-ROMANCE        # Modèles spécifiques
  $0 --clean --models en-de           # Forcer la reconversion
EOF
}

display_model_list() {
  printf "  %-22s %s\n" "CLÉ" "REPO HUGGINGFACE"
  printf "  %-22s %s\n" "---" "---"
  for key in "${ALL_MODELS[@]}"; do
    local bin="$DEST_DIR/$key/model.bin"
    local mark="  "; [[ -f "$bin" ]] && mark="✓ "
    printf "  %s%-20s %s\n" "$mark" "$key" "${MODEL_HF[$key]}"
  done
  echo ""
  echo "  ✓ = déjà converti   Total : ${#MODEL_HF[@]} modèles"
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
  echo "   Relancez pour reprendre depuis le dernier modèle non converti."
  exit 130
}
trap cleanup_packages EXIT
trap _on_interrupt INT TERM

# ─── Téléchargement d'un modèle ──────────────────────────────────────────────
# Utilise snapshot_download avec local_dir (pas de cache HF intermédiaire)
# et hf_transfer (backend Rust) pour les transferts larges fichiers.
_download_model() {
  local hf_id="$1" dest="$2"
  echo "  Téléchargement $hf_id…"
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
    ignore_patterns=["*.msgpack", "*.h5", "flax_model*", "tf_model*", "rust_model*"],
)
PYEOF
}

# ─── Arguments ────────────────────────────────────────────────────────────────
CLEAN=false
LIST_ONLY=false
SMALL_MODE=false
MODELS_FILTER=""
HF_TOKEN_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -l|--list)   LIST_ONLY=true; shift ;;
    -s|--small)  SMALL_MODE=true; shift ;;
    --clean)     CLEAN=true; shift ;;
    --models)
      [[ -z "${2:-}" || "${2:-}" == --* ]] && { echo "❌ --models requiert une liste de clés"; exit 1; }
      MODELS_FILTER="$2"; shift 2 ;;
    --hf-token)
      [[ -z "${2:-}" ]] && { echo "❌ --hf-token requiert un TOKEN"; exit 1; }
      HF_TOKEN_ARG="$2"; shift 2 ;;
    *) echo "❌ Option inconnue : $1"; usage; exit 1 ;;
  esac
done

if [[ "$LIST_ONLY" == true ]]; then display_model_list; exit 0; fi

# ─── Sélection ────────────────────────────────────────────────────────────────
if [[ "$SMALL_MODE" == true ]]; then
  MODELS_TO_DO=("${SMALL_MODELS[@]}")
  echo "Mode --small : ${MODELS_TO_DO[*]}"
elif [[ -n "$MODELS_FILTER" ]]; then
  IFS=',' read -ra MODELS_TO_DO <<< "$MODELS_FILTER"
  for _k in "${MODELS_TO_DO[@]}"; do
    [[ -z "${MODEL_HF[$_k]+x}" ]] && { echo "❌ Clé inconnue : '$_k'  (--list pour voir les clés)"; exit 1; }
  done
  echo "Sélection : ${MODELS_TO_DO[*]}"
else
  MODELS_TO_DO=("${ALL_MODELS[@]}")
  echo "Conversion de ${#MODELS_TO_DO[@]} modèles → $DEST_DIR"
fi
echo ""

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
  echo "ℹ  Aucun token HF (recommandé pour 24 téléchargements : --hf-token hf_xxx)"
fi
echo ""

# ─── Packages ─────────────────────────────────────────────────────────────────
setup_packages

# ─── Boucle de conversion ────────────────────────────────────────────────────
mkdir -p "$DEST_DIR"
TOTAL=${#MODELS_TO_DO[@]}
COUNT=0; DONE=0; FAILED=()

for key in "${MODELS_TO_DO[@]}"; do
  COUNT=$((COUNT + 1))
  hf_id="${MODEL_HF[$key]}"
  out_dir="$DEST_DIR/$key"

  if [[ "$CLEAN" == false && -f "$out_dir/model.bin" ]]; then
    DONE=$((DONE + 1))
    echo "[$COUNT/$TOTAL] $key — déjà converti ✓"
    continue
  fi

  echo ""; echo "[$COUNT/$TOTAL] $key ($hf_id)"

  # Téléchargement
  src_dir=$(mktemp -d)
  if ! _download_model "$hf_id" "$src_dir"; then
    echo "  ✗ $key — téléchargement échoué"
    FAILED+=("$key")
    rm -rf "$src_dir"
    continue
  fi

  # Conversion
  mkdir -p "$out_dir" && touch "$out_dir/.gitkeep"
  convert_exit=0
  PYTHONPATH="$PKGS_DIR" python3 "$SCRIPT_DIR/convert_model.py" "$src_dir" "$out_dir" \
    || convert_exit=$?

  rm -rf "$src_dir"

  if [[ $convert_exit -eq 130 || $convert_exit -eq 139 ]]; then
    _on_interrupt
  elif [[ $convert_exit -ne 0 ]]; then
    echo "  ✗ $key — conversion échouée (code $convert_exit)"
    FAILED+=("$key")
    find "$out_dir" -type f ! -name '.gitkeep' -delete 2>/dev/null || true
  else
    DONE=$((DONE + 1))
    echo "  [$DONE/$TOTAL] $key ✓"
  fi
done

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "Terminé : $DONE/$TOTAL convertis"
[[ -d "$DEST_DIR" ]] && echo "Taille   : $(du -sh "$DEST_DIR" | cut -f1)"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "Échecs (${#FAILED[@]}) : ${FAILED[*]}"
  echo "Réessayer : $0 --models $(IFS=','; echo "${FAILED[*]}")"
  exit 1
fi
echo "✅ Tous les modèles sont prêts."
