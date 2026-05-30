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
  -h, --help           Cette aide
  -l, --list           Liste les modèles sans télécharger
  -s, --small          4 modèles seulement (ja-en, ROMANCE-en, en-ROMANCE, en-de)
  -v, --verbose        Mode verbeux (logs Python visibles)
  --clean              Reconvertit les modèles déjà présents
  --hf-token TOKEN     Token HuggingFace (optionnel, évite le rate-limiting)

TOKEN HUGGINGFACE (optionnel — modèles publics, mais recommandé pour 24 téléchargements)
  Priorité : --hf-token > \$HF_TOKEN > huggingface-cli login (~/.cache/huggingface/token)
  Créer un token Read sur https://huggingface.co/settings/tokens

EXEMPLES
  $0                                  # Tout convertir (répertoire par défaut)
  $0 --small                          # Test rapide (4 modèles)
  $0 --list                           # Voir la liste sans télécharger
  $0 --clean en-ROMANCE               # Reconvertir un seul modèle
  $0 --hf-token hf_xxxx               # Avec token HuggingFace
  HF_TOKEN=hf_xxxx $0                 # Idem via variable d'environnement
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
  curl -fL --progress-bar "https://bootstrap.pypa.io/pip/pip.pyz" -o "$PIP_PYZ"
  echo ""

  echo "→ Installation des dépendances (ctranslate2, transformers, huggingface_hub, sentencepiece, sacremoses)..."
  echo "  (~2-5 min selon la connexion)"
  python3 "$PIP_PYZ" install \
    ctranslate2 \
    "transformers>=4.30" \
    "huggingface_hub>=0.20" \
    sentencepiece \
    sacremoses \
    --target "$PKGS_DIR" \
    --no-cache-dir

  _install_torch || {
    echo "❌ Impossible d'installer torch — conversion abandonnée."
    echo "   Workaround : sudo pip3 install torch --index-url https://download.pytorch.org/whl/cpu"
    echo "   Puis relancer ce script."
    exit 1
  }

  # Sanity check : les deux imports critiques doivent fonctionner
  local ct2_ver torch_ver
  ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "")
  torch_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")

  if [[ -z "$ct2_ver" || -z "$torch_ver" ]]; then
    echo ""
    echo "❌ Import check échoué :"
    [[ -z "$ct2_ver" ]] && echo "   ctranslate2 non importable — vérifier le log pip ci-dessus"
    [[ -z "$torch_ver" ]] && echo "   torch non importable — vérifier le log pip ci-dessus"
    echo "   PYTHONPATH=$PKGS_DIR"
    PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2, torch" 2>&1 | head -5
    exit 1
  fi

  echo ""
  echo "→ ctranslate2 $ct2_ver / torch $torch_ver prêts"
  echo ""
}

# ─── Installation de torch avec fallback PyPI ─────────────────────────────────
# Root cause : PyTorch héberge ses wheels sur Cloudflare R2 (download-r2.pytorch.org).
# Si ce CDN est inaccessible (résolution DNS échouée, pare-feu), on tombe sur PyPI.
# --upgrade évite les warnings "Target directory already exists" causés par les
# dépendances communes déjà installées (filelock, fsspec, etc.) lors du premier pip.
_install_torch() {
  if PYTHONPATH="$PKGS_DIR" python3 -c "import torch" 2>/dev/null; then
    echo "→ torch déjà disponible — installation ignorée"
    return 0
  fi

  echo "→ Installation de torch CPU (tentative 1/2 : PyTorch WHL ~200 MB)..."
  if python3 "$PIP_PYZ" install torch \
      --index-url https://download.pytorch.org/whl/cpu \
      --target "$PKGS_DIR" \
      --no-cache-dir \
      --upgrade; then
    return 0
  fi

  echo ""
  echo "⚠  CDN PyTorch inaccessible (download-r2.pytorch.org non résolu)."
  echo "→ Tentative 2/2 : PyPI standard (wheel CUDA+CPU, ~1.5 GB)..."
  python3 "$PIP_PYZ" install torch \
    --target "$PKGS_DIR" \
    --no-cache-dir \
    --upgrade
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

  mkdir -p "$dest"

  # Script Python de conversion injecté en heredoc
  local py_script
  py_script=$(mktemp /tmp/ct2_convert_XXXXXXXX.py)
  cat > "$py_script" <<'PYEOF'
import sys, os, glob, shutil, tempfile, traceback
import ctranslate2
from transformers import MarianTokenizer
from huggingface_hub import snapshot_download

hf_id, out_dir = sys.argv[1], sys.argv[2]

try:
    # OpusMTConverter attend un chemin LOCAL (ouvre decoder.yml sur disque).
    # snapshot_download télécharge le repo dans ~/.cache/huggingface/hub/ et
    # retourne le chemin local ; les appels suivants sont instantanés (cache).
    print(f"  Téléchargement {hf_id}...", flush=True)
    model_dir = snapshot_download(repo_id=hf_id)

    print(f"  Conversion CTranslate2 INT8...", flush=True)
    converter = ctranslate2.converters.OpusMTConverter(model_dir)
    converter.convert(out_dir, quantization="int8", force=True)
    print(f"  model.bin + shared_vocabulary.json générés")

    print(f"  Tokenizer SPM...", flush=True)
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
            print(f"  SPM déjà présents")

    model_bin = os.path.join(out_dir, "model.bin")
    if not os.path.exists(model_bin):
        print(f"  ✗ model.bin absent dans {out_dir}", file=sys.stderr)
        sys.exit(1)

    size = sum(os.path.getsize(os.path.join(out_dir, f))
               for f in os.listdir(out_dir)) / 1024 / 1024
    print(f"  ✓ {out_dir} ({size:.0f} MB)")

except Exception as e:
    traceback.print_exc(file=sys.stderr)
    print(f"  ✗ {hf_id} : {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  # Capturer le code de sortie avant rm -f :
  # Quand convert_model est appelée dans un `if`, bash suspend set -e à l'intérieur
  # de la fonction. Sans cette capture, rm -f (exit 0) masque l'échec de python3.
  local py_exit=0
  PYTHONPATH="$PKGS_DIR" python3 "$py_script" "$hf_id" "$dest" || py_exit=$?
  rm -f "$py_script"
  return $py_exit
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
VERBOSE=false
LIST_ONLY=false
SMALL_MODE=false
CLEAN=false
DEST_DIR="$DEFAULT_DEST"
HF_TOKEN_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -l|--list)    LIST_ONLY=true; shift ;;
    -s|--small)   SMALL_MODE=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    --clean)      CLEAN=true; shift ;;
    --hf-token)
      [[ -z "${2:-}" ]] && { echo "--hf-token requiert un TOKEN"; exit 1; }
      HF_TOKEN_ARG="$2"; shift 2 ;;
    -*)           echo "Option inconnue : $1"; usage; exit 1 ;;
    *)            DEST_DIR="$1"; shift ;;
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

# ─── Token HuggingFace ────────────────────────────────────────────────────────
# huggingface_hub lit HF_TOKEN automatiquement dans snapshot_download().
# Priorité : --hf-token > $HF_TOKEN existant > huggingface-cli login.
if [[ -n "$HF_TOKEN_ARG" ]]; then
  export HF_TOKEN="$HF_TOKEN_ARG"
  echo "→ Token HuggingFace : --hf-token"
elif [[ -n "${HF_TOKEN:-}" ]]; then
  echo "→ Token HuggingFace : variable \$HF_TOKEN"
elif [[ -f "$HOME/.cache/huggingface/token" ]]; then
  export HF_TOKEN="$(< "$HOME/.cache/huggingface/token")"
  echo "→ Token HuggingFace : ~/.cache/huggingface/token"
else
  echo "ℹ  Aucun token HuggingFace — les modèles publics fonctionnent sans."
  echo "   Pour éviter le rate-limiting sur 24 téléchargements :"
  echo "   $0 --hf-token hf_xxxx   ou   export HF_TOKEN=hf_xxxx"
fi
echo ""

# ─── Packages de conversion ───────────────────────────────────────────────────
setup_packages

# ─── Barre de progression globale ────────────────────────────────────────────
_print_bar() {
  local current=$1 total=$2 label="$3"
  local width=36 bar="" i
  for (( i=0; i<width; i++ )); do
    [[ $i -lt $(( current * width / total )) ]] && bar+="█" || bar+="░"
  done
  printf "  [%s] %2d/%d  %s\n" "$bar" "$current" "$total" "$label"
}

# ─── Boucle de conversion ────────────────────────────────────────────────────
TOTAL=${#MODELS_TO_DO[@]}
COUNT=0
DONE=0
FAILED=()

for key in "${MODELS_TO_DO[@]}"; do
  COUNT=$((COUNT + 1))
  out_dir="$DEST_DIR/$key"

  if [[ "$CLEAN" == false && -f "$out_dir/model.bin" ]]; then
    DONE=$((DONE + 1))
    echo "[$COUNT/$TOTAL] $key — déjà converti, ignoré (--clean pour forcer)"
    _print_bar "$DONE" "$TOTAL" "$key"
    continue
  fi

  echo ""
  echo "[$COUNT/$TOTAL] $key (${MODEL_HF[$key]})..."

  if convert_model "$key" "$out_dir"; then
    DONE=$((DONE + 1))
    _print_bar "$DONE" "$TOTAL" "$key ✓"
  else
    echo "  ✗ $key — échec"
    FAILED+=("$key")
    rm -rf "$out_dir"
    _print_bar "$DONE" "$TOTAL" "$key ✗"
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
