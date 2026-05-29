#!/bin/bash
#
# Prépare les modèles de traduction Opus-MT pour le graphe de pivots.
#
# Télécharge les modèles PyTorch depuis Helsinki-NLP (HuggingFace) et les
# convertit au format CTranslate2 INT8 via un venv temporaire.
#
# Usage :
#   ./prepare_translation_models.sh [OPTIONS] [DEST_DIR]
#
# Options :
#   -h, --help     Affiche cette aide
#   -l, --list     Liste les modèles sans télécharger
#   -s, --small    Télécharge 4 modèles seulement (test rapide)
#   -v, --verbose  Mode verbeux
#   --clean        Supprime et reconvertit les modèles déjà présents
#
# DEST_DIR : flutter_app/assets/translation_models/ par défaut
#
# Prérequis :
#   python3, curl
#   ~2 GB d'espace libre (packages temporaires + modèles convertis)
#   ~1-3 h au premier build selon la connexion (24 modèles × ~200 MB)
#   Les builds suivants sont instantanés (modèles déjà présents).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEST="$SCRIPT_DIR/../flutter_app/assets/translation_models"

# ─── Graphe de modèles ────────────────────────────────────────────────────────
# Clé  = nom du répertoire de sortie (= ce que translation_service.dart attend)
# Valeur = repo HuggingFace Helsinki-NLP
declare -A MODEL_HF=(
  # Pivot entrants : Source → Anglais
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
  ["ROMANCE-en"]="Helsinki-NLP/opus-mt-ROMANCE-en"   # fr, es, it, pt → en

  # Pivot sortants : Anglais → Cible
  ["en-ROMANCE"]="Helsinki-NLP/opus-mt-en-ROMANCE"   # en → fr (>>fr<<), es, it, pt
  ["en-de"]="Helsinki-NLP/opus-mt-en-de"
  ["en-nl"]="Helsinki-NLP/opus-mt-en-nl"
  ["en-ru"]="Helsinki-NLP/opus-mt-en-ru"
  ["en-hi"]="Helsinki-NLP/opus-mt-en-hi"
  ["en-zh"]="Helsinki-NLP/opus-mt-en-zh"             # token >>cmn<<
  ["en-ar"]="Helsinki-NLP/opus-mt-en-ar"             # token >>ara<<  (garder aussi tc-big)
  ["en-vi"]="Helsinki-NLP/opus-mt-en-vi"             # token >>vie<<
  ["en-mul"]="Helsinki-NLP/opus-mt-en-mul"           # token >>jpn<< >>tha<<
  ["en-sla"]="Helsinki-NLP/opus-mt-en-sla"           # token >>pol<<
  ["tc-big-en-ar"]="Helsinki-NLP/opus-mt-tc-big-en-ar"  # token >>ara<< (qualité supérieure)
  ["tc-big-en-ko"]="Helsinki-NLP/opus-mt-tc-big-en-ko"  # en → ko (dédié)
)

ALL_MODELS=(
  "ja-en" "zh-en" "ko-en" "ru-en" "ar-en" "hi-en" "th-en" "vi-en"
  "de-en" "nl-en" "pl-en" "ROMANCE-en"
  "en-ROMANCE" "en-de" "en-nl" "en-ru" "en-hi" "en-zh" "en-ar"
  "en-vi" "en-mul" "en-sla" "tc-big-en-ar" "tc-big-en-ko"
)

# 4 modèles pour test rapide (clés valides dans MODEL_HF)
SMALL_MODELS=("ja-en" "ROMANCE-en" "en-ROMANCE" "en-de")

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [DEST_DIR]

Convertit les modèles Helsinki-NLP opus-mt en CTranslate2 INT8.
Destination par défaut : flutter_app/assets/translation_models/

OPTIONS
  -h, --help     Cette aide
  -l, --list     Liste les modèles sans télécharger
  -s, --small    4 modèles seulement (ja-en, ROMANCE-en, en-ROMANCE, en-de)
  -v, --verbose  Mode verbeux (logs Python visibles)
  --clean        Reconvertit les modèles déjà présents

EXEMPLES
  $0                         # Tout convertir dans le répertoire par défaut
  $0 --small                 # Test rapide (4 modèles)
  $0 --list                  # Voir la liste sans télécharger
  $0 --clean en-ROMANCE      # Reconvertir un seul modèle
EOF
}

# ─── Liste des modèles ────────────────────────────────────────────────────────
display_model_list() {
  printf "%-20s %-45s\n" "RÉPERTOIRE" "REPO HUGGINGFACE"
  printf "%-20s %-45s\n" "---" "---"
  printf "\n=== PIVOT ENTRANTS (Source → Anglais) ===\n"
  for key in "ja-en" "zh-en" "ko-en" "ru-en" "ar-en" "hi-en" "th-en" "vi-en" \
             "de-en" "nl-en" "pl-en" "ROMANCE-en"; do
    printf "  %-18s %s\n" "$key" "${MODEL_HF[$key]}"
  done
  printf "\n=== PIVOT SORTANTS (Anglais → Cible) ===\n"
  for key in "en-ROMANCE" "en-de" "en-nl" "en-ru" "en-hi" "en-zh" "en-ar" \
             "en-vi" "en-mul" "en-sla" "tc-big-en-ar" "tc-big-en-ko"; do
    printf "  %-18s %s\n" "$key" "${MODEL_HF[$key]}"
  done
  echo ""
  echo "Total : ${#MODEL_HF[@]} modèles"
}

# ─── Venv de conversion ───────────────────────────────────────────────────────
# Répertoire de packages temporaires (--target, pas de venv requis)
PKGS_DIR=""
PIP_PYZ=""

setup_packages() {
  PKGS_DIR=$(mktemp -d /tmp/ct2pkgs_XXXXXXXX)
  PIP_PYZ=$(mktemp /tmp/pip_XXXXXXXX.pyz)

  echo "→ Téléchargement de pip bootstrap..."
  curl -fsSL "https://bootstrap.pypa.io/pip/pip.pyz" -o "$PIP_PYZ"

  echo "→ Installation des dépendances de conversion dans $PKGS_DIR"
  echo "  ctranslate2, transformers, torch (CPU), sentencepiece, sacremoses"
  echo "  (~5-10 min selon la connexion, une seule fois par build)"
  echo ""

  # Packages sans torch d'abord
  python3 "$PIP_PYZ" install \
    ctranslate2 \
    "transformers>=4.30" \
    sentencepiece \
    sacremoses \
    --target "$PKGS_DIR" \
    --no-cache-dir \
    --quiet

  # torch CPU (index dédié pour éviter le wheel CUDA de 2 GB)
  python3 "$PIP_PYZ" install \
    torch \
    --index-url https://download.pytorch.org/whl/cpu \
    --target "$PKGS_DIR" \
    --no-cache-dir \
    --quiet

  local ct2_ver
  ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "?")
  echo "→ ctranslate2 $ct2_ver prêt"
  echo ""
}

cleanup_packages() {
  [[ -n "$PKGS_DIR" && -d "$PKGS_DIR" ]] && rm -rf "$PKGS_DIR"
  [[ -n "$PIP_PYZ"  && -f "$PIP_PYZ"  ]] && rm -f  "$PIP_PYZ"
}
trap cleanup_packages EXIT

# ─── Conversion d'un modèle ───────────────────────────────────────────────────
convert_model() {
  local key="$1"      # ex: "ja-en"
  local dest="$2"     # ex: "flutter_app/assets/translation_models/ja-en"
  local hf_id="${MODEL_HF[$key]}"
  local quiet_flag=""
  [[ "$VERBOSE" == false ]] && quiet_flag="2>/dev/null"

  mkdir -p "$dest"

  # Script Python de conversion injecté en heredoc
  local py_script
  py_script=$(mktemp /tmp/ct2_convert_XXXXXXXX.py)
  cat > "$py_script" <<'PYEOF'
import sys, os, glob, shutil, tempfile
import ctranslate2
from transformers import MarianTokenizer

hf_id, out_dir = sys.argv[1], sys.argv[2]

print(f"  OpusMTConverter({hf_id})...")
converter = ctranslate2.converters.OpusMTConverter(hf_id)
converter.convert(out_dir, quantization="int8", force=True)
print(f"  model.bin + shared_vocabulary.json générés")

print(f"  Tokenizer : source.spm / target.spm...")
with tempfile.TemporaryDirectory() as tmp:
    tok = MarianTokenizer.from_pretrained(hf_id)
    tok.save_pretrained(tmp)
    copied = []
    for pattern in ("*.spm", "*.model"):
        for f in glob.glob(os.path.join(tmp, pattern)):
            dst = os.path.join(out_dir, os.path.basename(f))
            if not os.path.exists(dst):
                shutil.copy(f, dst)
                copied.append(os.path.basename(f))
    if copied:
        print(f"  Copiés : {', '.join(copied)}")
    else:
        print(f"  Fichiers SPM déjà présents")

size = sum(os.path.getsize(os.path.join(out_dir, f))
           for f in os.listdir(out_dir)) / 1024 / 1024
print(f"  ✓ {out_dir} ({size:.0f} MB)")
PYEOF

  if [[ "$VERBOSE" == true ]]; then
    PYTHONPATH="$PKGS_DIR" python3 "$py_script" "$hf_id" "$dest"
  else
    PYTHONPATH="$PKGS_DIR" python3 "$py_script" "$hf_id" "$dest" 2>/dev/null
  fi

  rm -f "$py_script"
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
VERBOSE=false
LIST_ONLY=false
SMALL_MODE=false
CLEAN=false
DEST_DIR="$DEFAULT_DEST"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -l|--list)   LIST_ONLY=true; shift ;;
    -s|--small)  SMALL_MODE=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    --clean)     CLEAN=true; shift ;;
    -*)          echo "Option inconnue : $1"; usage; exit 1 ;;
    *)           DEST_DIR="$1"; shift ;;
  esac
done

# ─── Liste seule ─────────────────────────────────────────────────────────────
if [[ "$LIST_ONLY" == true ]]; then
  display_model_list
  exit 0
fi

# ─── Sélection des modèles ───────────────────────────────────────────────────
if [[ "$SMALL_MODE" == true ]]; then
  MODELS_TO_DO=("${SMALL_MODELS[@]}")
  echo "Mode --small : ${#MODELS_TO_DO[@]} modèles (${MODELS_TO_DO[*]})"
else
  MODELS_TO_DO=("${ALL_MODELS[@]}")
  echo "Conversion de ${#MODELS_TO_DO[@]} modèles → $DEST_DIR"
fi
echo ""

mkdir -p "$DEST_DIR"

# ─── Packages de conversion ───────────────────────────────────────────────────
setup_packages

# ─── Boucle de conversion ────────────────────────────────────────────────────
TOTAL=${#MODELS_TO_DO[@]}
COUNT=0
FAILED=()

for key in "${MODELS_TO_DO[@]}"; do
  COUNT=$((COUNT + 1))
  out_dir="$DEST_DIR/$key"

  if [[ "$CLEAN" == false && -f "$out_dir/model.bin" ]]; then
    echo "[$COUNT/$TOTAL] $key — déjà converti, ignoré (--clean pour forcer)"
    continue
  fi

  echo "[$COUNT/$TOTAL] $key (${MODEL_HF[$key]})..."

  if convert_model "$key" "$out_dir"; then
    echo "  ✓ $key"
  else
    echo "  ✗ $key — échec"
    FAILED+=("$key")
    rm -rf "$out_dir"   # ne pas laisser un répertoire partiel
  fi
  echo ""
done

# ─── Résumé ──────────────────────────────────────────────────────────────────
OK=$((TOTAL - ${#FAILED[@]}))
echo "════════════════════════════════════════"
echo "Terminé : $OK/$TOTAL modèles convertis"
echo "Destination : $(realpath "$DEST_DIR")"
[[ -d "$DEST_DIR" ]] && echo "Taille totale : $(du -sh "$DEST_DIR" | cut -f1)"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "Échecs (${#FAILED[@]}) :"
  printf "  %s\n" "${FAILED[@]}"
  echo ""
  echo "Pour réessayer : $0 --clean $(IFS=' '; echo "${FAILED[*]}")"
  exit 1
fi

echo "✅ Tous les modèles sont prêts."
