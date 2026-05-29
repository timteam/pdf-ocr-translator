#!/bin/bash
#
# Script de préparation des modèles de traduction OPUS-MT
#
# Ce script télécharge et prépare les modèles de traduction nécessaires
# pour le graphe de pivots défini dans translation_service.dart.
#
# Architecture : étoile centrée sur l'anglais (en)
#   - Source → EN  (modèles pivot entrants)
#   - EN → Cible  (modèles pivot sortants)
#
# Usage:
#   ./prepare_translation_models.sh [dest_dir]
#
# Si dest_dir n'est pas spécifié, utilise :
#   - flutter_app/assets/translation_models/ (par défaut)
#
# Nécessite :
#   - ctranslate2 (pour la conversion des modèles)
#   - git-lfs (pour télécharger les modèles)
#   - Python 3.10+
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Répertoire de destination par défaut
DEFAULT_DEST="flutter_app/assets/translation_models"

# Organisation des modèles OPUS-MT sur HuggingFace
# Format : HF_REPO:MODEL_NAME
declare -A MODEL_MAP=(
  # Pivot entrants : Source → Anglais
  ["ja-en"]="Helsinki-NLP/opus-mt-ja-en:opus-mt-ja-en"
  ["zh-en"]="Helsinki-NLP/opus-mt-zh-en:opus-mt-zh-en"
  ["ko-en"]="Helsinki-NLP/opus-mt-ko-en:opus-mt-ko-en"
  ["ru-en"]="Helsinki-NLP/opus-mt-ru-en:opus-mt-ru-en"
  ["ar-en"]="Helsinki-NLP/opus-mt-ar-en:opus-mt-ar-en"
  ["hi-en"]="Helsinki-NLP/opus-mt-hi-en:opus-mt-hi-en"
  ["th-en"]="Helsinki-NLP/opus-mt-th-en:opus-mt-th-en"
  ["vi-en"]="Helsinki-NLP/opus-mt-vi-en:opus-mt-vi-en"
  ["de-en"]="Helsinki-NLP/opus-mt-de-en:opus-mt-de-en"
  ["nl-en"]="Helsinki-NLP/opus-mt-nl-en:opus-mt-nl-en"
  ["pl-en"]="Helsinki-NLP/opus-mt-pl-en:opus-mt-pl-en"
  ["ROMANCE-en"]="Helsinki-NLP/opus-mt-ROMANCE-en:opus-mt-ROMANCE-en"

  # Pivot sortants : Anglais → Cible
  ["en-ROMANCE"]="Helsinki-NLP/opus-mt-en-ROMANCE:opus-mt-en-ROMANCE"
  ["en-zh"]="Helsinki-NLP/opus-mt-en-zh:opus-mt-en-zh"
  ["en-de"]="Helsinki-NLP/opus-mt-en-de:opus-mt-en-de"
  ["en-nl"]="Helsinki-NLP/opus-mt-en-nl:opus-mt-en-nl"
  ["en-ru"]="Helsinki-NLP/opus-mt-en-ru:opus-mt-en-ru"
  ["en-hi"]="Helsinki-NLP/opus-mt-en-hi:opus-mt-en-hi"
  ["en-vi"]="Helsinki-NLP/opus-mt-en-vi:opus-mt-en-vi"
  ["en-mul"]="Helsinki-NLP/opus-mt-en-mul:opus-mt-en-mul"
  ["en-sla"]="Helsinki-NLP/opus-mt-en-sla:opus-mt-en-sla"

  # Modèles TC-Big (Transformers + CTranslate2 optimisés)
  ["tc-big-en-ar"]="argostranslate/argos-opus-en-ar:tc-big"
  ["tc-big-en-ko"]="argostranslate/argos-opus-en-ko:tc-big"
)

# Modèles à télécharger (tous)
ALL_MODELS=(
  "ja-en" "zh-en" "ko-en" "ru-en" "ar-en" "hi-en" "th-en" "vi-en"
  "de-en" "nl-en" "pl-en" "ROMANCE-en"
  "en-ROMANCE" "en-zh" "en-de" "en-nl" "en-ru" "en-hi" "en-vi"
  "en-mul" "en-sla"
  "tc-big-en-ar" "tc-big-en-ko"
)

# ============================================================================
# FONCTIONS
# ============================================================================

# Affiche l'aide
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [DEST_DIR]

Télécharge et prépare les modèles de traduction pour le graphe de pivots.

Arguments:
  DEST_DIR       Répertoire de destination (défaut: $DEFAULT_DEST)

Options:
  -h, --help     Affiche cette aide
  -l, --list     Liste les modèles disponibles sans télécharger
  -s, --small    Télécharge seulement les modèles petits (pour test)
  -v, --verbose  Mode verbeux
  --clean        Supprime les modèles existants avant téléchargement

Exemples:
  $0                              # Télécharge tout dans $DEFAULT_DEST
  $0 flutter_app/assets/translation_models
  $0 --list                       # Liste les modèles sans télécharger
  $0 --small my_models/           # Télécharge un sous-ensemble
EOF
}

# Affiche la liste des modèles
display_model_list() {
  echo "Modèles de traduction disponibles (graphe de pivots):"
  echo ""
  echo "=== PIVOT ENTRANTS (Source → Anglais) ==="
  for model in "${!MODEL_MAP[@]}"; do
    if [[ $model == *"-en" ]]; then
      printf "  %-20s %s\n" "$model" "${MODEL_MAP[$model]}"
    fi
  done
  echo ""
  echo "=== PIVOT SORTANTS (Anglais → Cible) ==="
  for model in "${!MODEL_MAP[@]}"; do
    if [[ $model == "en-"* ]]; then
      printf "  %-20s %s\n" "$model" "${MODEL_MAP[$model]}"
    fi
  done
  echo ""
  echo "Total: ${#MODEL_MAP[@]} modèles"
}

# Vérifie les dépendances
check_dependencies() {
  local missing=()

  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  command -v pip >/dev/null 2>&1 || missing+=("pip")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERREUR: Dépendances manquantes: ${missing[*]}"
    echo ""
    echo "Installez-les avec :"
    echo "  Ubuntu/Debian: sudo apt-get install curl python3 python3-pip"
    echo "  macOS: brew install curl python"
    exit 1
  fi

  # Vérifie ctranslate2
  if ! python3 -c "import ctranslate2" 2>/dev/null; then
    echo "Installation de ctranslate2..."
    pip install ctranslate2[cpu] --quiet
  fi

  echo "✓ Toutes les dépendances sont installées"
}

# Convertit un modèle HuggingFace en format CTranslate2
# Utilise curl pour télécharger directement depuis HuggingFace (sans git-lfs)
convert_model() {
  local hf_repo="$1"
  local output_dir="$2"
  local model_name="$3"

  echo "  Conversion de $model_name depuis $hf_repo..."

  # Crée un répertoire temporaire pour la conversion
  local tmp_dir=$(mktemp -d)
  trap "rm -rf $tmp_dir" EXIT

  # Extrait le nom du modèle depuis la configuration
  local hf_model="${MODEL_MAP[$model_name]}"
  # Si le format est REPO:MODEL, extraire le modèle
  if [[ "$hf_model" == *":"* ]]; then
    hf_model=$(echo "$hf_model" | cut -d':' -f2)
  else
    hf_model="$hf_model"
  fi

  # Télécharge le répertoire du modèle via curl + HF API
  # HuggingFace : https://huggingface.co/{repo}/resolve/main/{file}
  local model_url="https://huggingface.co/${hf_repo}"
  local model_path="$tmp_dir/model"
  mkdir -p "$model_path"

  # Télécharge tous les fichiers nécessaires depuis HuggingFace
  # Pour les modèles Transformers, on a besoin de :
  # - config.json
  # - pytorch_model.bin (ou tf_model.h5)
  # - tokenizer.json / tokenizer_config.json
  # - special_tokens_map.json
  # - vocab.txt (ou sentencepiece.bpe.model, etc.)
  
  echo "  Téléchargement des fichiers depuis HuggingFace..."
  
  # Liste des fichiers à télécharger pour un modèle OPUS-MT
  local files_to_download=(
    "config.json"
    "pytorch_model.bin"
    "tokenizer.json"
    "tokenizer_config.json"
    "special_tokens_map.json"
    "source.spm"
    "target.spm"
    "sentencepiece.bpe.model"
    "vocab.json"
  )

  for file in "${files_to_download[@]}"; do
    if curl -s -f -L "${model_url}/resolve/main/${file}" -o "${model_path}/${file}" 2>/dev/null; then
      echo "    ✓ Téléchargé: $file"
    else
      # Essayer sans resolve/main
      if curl -s -f -L "${model_url}/${file}" -o "${model_path}/${file}" 2>/dev/null; then
        echo "    ✓ Téléchargé: $file (chemin direct)"
      else
        echo "    ⚠ Non trouvé: $file"
      fi
    fi
  done

  # Vérifier qu'on a au moins pytorch_model.bin ou un fichier de poids
  if [ ! -f "${model_path}/pytorch_model.bin" ] && [ ! -f "${model_path}/model.safetensors" ] && [ ! -f "${model_path}/model.bin" ]; then
    echo "  ❌ Aucun fichier de poids trouvé pour ${model_name}"
    return 1
  fi

  # Convertit en CTranslate2
  python3 - <<PYEOF
import ctranslate2
import os
import shutil

model_path = "$tmp_dir/model"
output_path = "$output_dir"

# Charge le modèle Transformers
model = ctranslate2.converters.TransformersConverter().convert(
    model_path,
    output_dir=output_path,
    quantization="int8",
    force=True
)

# Copie les fichiers SentencePiece depuis le modèle source
sp_files = ["source.spm", "target.spm", "sentencepiece.bpe.model", "vocab.json"]
for sp_file in sp_files:
    src = os.path.join(model_path, sp_file)
    if os.path.exists(src):
        shutil.copy2(src, output_path)
        print(f"  ✓ SentencePiece copié: {sp_file}")

print(f"  ✓ Modèle converti: {output_path}")
PYEOF

  # Nettoyage : garde seulement les fichiers nécessaires
  if [ -d "$output_dir" ]; then
    # Supprime les fichiers inutiles (mais garde vocab*.txt pour SPM)
    find "$output_dir" -name "*.txt" -not -name "vocab*" -delete 2>/dev/null || true
    find "$output_dir" -name "*.md" -delete 2>/dev/null || true
    find "$output_dir" -name "config.json" -delete 2>/dev/null || true
  fi
}

# Télécharge et prépare un modèle
prepare_model() {
  local model_name="$1"
  local dest_dir="$2"
  local model_output_dir="$dest_dir/$model_name"

  echo "Préparation du modèle: $model_name"

  # Vérifie si le modèle existe déjà
  if [ -d "$model_output_dir" ] && [ "$(ls -A "$model_output_dir" 2>/dev/null)" ]; then
    echo "  ✓ Modèle existe déjà: $model_name"
    return 0
  fi

  mkdir -p "$model_output_dir"

  # Récupère la configuration du modèle
  local hf_info="${MODEL_MAP[$model_name]}"
  local hf_repo=$(echo "$hf_info" | cut -d':' -f1)
  local hf_model=$(echo "$hf_info" | cut -d':' -f2)

  # Télécharge et convertit
  convert_model "$hf_repo" "$model_output_dir" "$model_name"

  # Crée un fichier README avec la configuration
  cat > "$model_output_dir/README.md" <<EOF
# Modèle de traduction: $model_name

- **Source**: $hf_repo
- **Modèle**: $hf_model
- **Format**: CTranslate2 (quantifié INT8)
- **Taille**: $(du -sh "$model_output_dir" | cut -f1)

Généré par: $0
Date: $(date)
EOF

  echo "  ✓ Modèle prêt: $model_name"
}

# ============================================================================
# MODE SMALL (pour test)
# ============================================================================

# Sous-ensemble de modèles pour test rapide
SMALL_MODELS=(
  "fr-en"    # ROMANCE-en pour test (petit)
  "en-fr"    # en-ROMANCE pour test
  "de-en"
  "en-de"
)

# ============================================================================
# MAIN
# ============================================================================

# Parse les arguments
VERBOSE=false
LIST_ONLY=false
SMALL_MODE=false
CLEAN=false
DEST_DIR="$DEFAULT_DEST"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -l|--list)
      LIST_ONLY=true
      shift
      ;;
    -s|--small)
      SMALL_MODE=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    -*)
      echo "Option inconnue: $1"
      usage
      exit 1
      ;;
    *)
      DEST_DIR="$1"
      shift
      ;;
  esac
done

# Affiche la liste si demandé
if [ "$LIST_ONLY" = true ]; then
  display_model_list
  exit 0
fi

# Vérifie les dépendances
if [ "$LIST_ONLY" = false ]; then
  echo "Vérification des dépendances..."
  check_dependencies
  echo ""
fi

# Détermine les modèles à télécharger
if [ "$SMALL_MODE" = true ]; then
  echo "Mode SMALL: Téléchargement de ${#SMALL_MODELS[@]} modèles seulement"
  MODELS_TO_DOWNLOAD=("${SMALL_MODELS[@]}")
else
  echo "Téléchargement de tous les modèles (${#ALL_MODELS[@]})"
  MODELS_TO_DOWNLOAD=("${ALL_MODELS[@]}")
fi

# Nettoyage si demandé
if [ "$CLEAN" = true ]; then
  echo "Nettoyage du répertoire de destination..."
  rm -rf "$DEST_DIR"
  mkdir -p "$DEST_DIR"
fi

# Crée le répertoire de destination
mkdir -p "$DEST_DIR"

# Télécharge chaque modèle
echo ""
echo "Début du téléchargement..."
echo "Répertoire de destination: $(realpath "$DEST_DIR")"
echo ""

TOTAL=${#MODELS_TO_DOWNLOAD[@]}
COUNT=0
FAILED=()

for model in "${MODELS_TO_DOWNLOAD[@]}"; do
  COUNT=$((COUNT + 1))
  echo "[$COUNT/$TOTAL] $model"

  if prepare_model "$model" "$DEST_DIR"; then
    : # Succès
  else
    FAILED+=("$model")
    echo "  ✗ ÉCHEC: $model"
  fi
  echo ""
done

# Résumé
echo "========================================================================"
echo "SUMMARY"
echo "========================================================================"
echo "Modèles réussis: $((TOTAL - ${#FAILED[@]}))/$TOTAL"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "Modèles en échec (${#FAILED[@]}):"
  for model in "${FAILED[@]}"; do
    echo "  - $model"
  done
  echo ""
  echo "Pour réessayer les modèles en échec:"
  echo "  $0 --verbose ${FAILED[*]}"
fi

echo ""
echo "Répertoire de sortie: $(realpath "$DEST_DIR")"
echo "Taille totale: $(du -sh "$DEST_DIR" | cut -f1)"
echo ""
echo "✓ Préparation terminée!"
