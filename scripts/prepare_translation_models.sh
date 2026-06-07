#!/bin/bash
#
# Télécharge les modèles Opus-MT (format Argos/CTranslate2) depuis argos-net.com.
#
# Usage :
#   ./scripts/prepare_translation_models.sh [OPTIONS] [PAIRES...]
#
# OPTIONS
#   -h, --help      Cette aide
#   --clean         Re-télécharge même si le modèle existe déjà
#   --list          Liste les paires disponibles dans l'index Argos et quitte
#
# PAIRES (optionnel)
#   Ex : ja-en en-fr ru-en en-de
#   Si omises, télécharge toutes les paires déclarées dans pubspec.yaml
#   qui ont un modèle disponible dans l'index Argos.
#
# ARCHITECTURE
#   Pivot via l'anglais : ja→fr = ja-en + en-fr (deux modèles)
#   Chaque répertoire contient :
#     model/model.bin        — CTranslate2
#     sentencepiece.model    — tokenizer partagé
#
# DEST_DIR : flutter_app/assets/translation_models/ (fixé par pubspec.yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../flutter_app/assets/translation_models"
INDEX_URL="https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ─── Aide ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [PAIRES...]

Télécharge les modèles Opus-MT (Argos) pour la traduction OCR.

OPTIONS
  -h, --help      Cette aide
  --clean         Re-télécharge même si déjà présent
  --list          Liste les paires disponibles dans l'index Argos

PAIRES (optionnel, format {from}-{to})
  ja-en en-fr ru-en …
  Si omises : toutes les paires déclarées dans pubspec.yaml

EXEMPLES
  $0                    # Tout télécharger (selon pubspec.yaml)
  $0 ja-en en-fr        # Seulement ces deux paires
  $0 --clean ja-en      # Forcer le re-téléchargement de ja-en
  $0 --list             # Voir ce qui est disponible
EOF
}

# ─── Arguments ────────────────────────────────────────────────────────────────
CLEAN=false
LIST_ONLY=false
REQUESTED_PAIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    --clean)    CLEAN=true; shift ;;
    --list)     LIST_ONLY=true; shift ;;
    -*)         echo "❌ Option inconnue : $1"; usage; exit 1 ;;
    *)          REQUESTED_PAIRS+=("$1"); shift ;;
  esac
done

# ─── Récupération de l'index Argos ────────────────────────────────────────────
echo -e "${BLUE}→ Récupération de l'index Argos…${NC}"
INDEX_JSON=$(curl -sf "$INDEX_URL" 2>/dev/null) || {
  echo -e "${RED}❌ Impossible de joindre l'index Argos : $INDEX_URL${NC}"
  exit 1
}

# Construit une map from-to → url depuis l'index JSON
declare -A ARGOS_URLS
eval "$(echo "$INDEX_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data:
    fc = p.get('from_code','')
    tc = p.get('to_code','')
    links = p.get('links', [])
    if fc and tc and links:
        # Échappe pour bash
        key = fc + '-' + tc
        url = links[0]
        print(f'ARGOS_URLS[\"{key}\"]=\"{url}\"')
")"

if $LIST_ONLY; then
  echo ""
  echo "Paires disponibles dans l'index Argos :"
  for key in $(echo "${!ARGOS_URLS[@]}" | tr ' ' '\n' | sort); do
    from="${key%-*}"; to="${key#*-}"
    echo "  $key  →  ${ARGOS_URLS[$key]##*/}"
  done
  exit 0
fi

# ─── Paires à télécharger ─────────────────────────────────────────────────────
if [[ ${#REQUESTED_PAIRS[@]} -eq 0 ]]; then
  # Extraire les paires depuis pubspec.yaml
  REQUESTED_PAIRS=()
  while IFS= read -r line; do
    if [[ "$line" =~ assets/translation_models/([a-z]+-[a-z]+)/ ]]; then
      REQUESTED_PAIRS+=("${BASH_REMATCH[1]}")
    fi
  done < "$SCRIPT_DIR/../flutter_app/pubspec.yaml"
fi

echo -e "${BLUE}→ Paires demandées : ${REQUESTED_PAIRS[*]}${NC}"
echo ""

# ─── Téléchargement ───────────────────────────────────────────────────────────
ok=0; skipped=0; failed=0; unavailable=0

for pair in "${REQUESTED_PAIRS[@]}"; do
  OUT_DIR="$DEST_DIR/$pair"
  MODEL_BIN="$OUT_DIR/model/model.bin"

  if [[ "$CLEAN" == false && -f "$MODEL_BIN" ]]; then
    size=$(du -sh "$MODEL_BIN" | cut -f1)
    echo -e "${GREEN}✓ $pair ($size) — déjà présent${NC}"
    ((skipped++)) || true
    continue
  fi

  if [[ -z "${ARGOS_URLS[$pair]:-}" ]]; then
    echo -e "${YELLOW}⚠  $pair — aucun modèle dans l'index Argos${NC}"
    ((unavailable++)) || true
    continue
  fi

  URL="${ARGOS_URLS[$pair]}"
  ZIP="/tmp/argos_${pair}.argosmodel"
  EXTRACT="/tmp/argos_extract_${pair}"

  echo -e "${BLUE}↓  $pair${NC} — ${URL##*/}"

  # Téléchargement avec retries et reprise automatique
  _MAX_TRIES=3
  _try=0
  _dl_ok=false
  while [[ $_try -lt $_MAX_TRIES ]]; do
    ((_try++)) || true
    # -C - : reprend un téléchargement partiel si le zip existe déjà
    # --retry 3 --retry-delay 2 : retries réseau intra-curl
    if curl -fL --progress-bar --retry 3 --retry-delay 2 \
            --connect-timeout 30 --max-time 600 \
            -C - "$URL" -o "$ZIP" 2>&1; then
      # Vérifie l'intégrité du zip avant d'extraire
      if unzip -t "$ZIP" &>/dev/null; then
        _dl_ok=true
        break
      else
        echo -e "${YELLOW}   ⚠  Tentative $_try/$_MAX_TRIES — zip corrompu, re-téléchargement complet${NC}"
        rm -f "$ZIP"  # supprime le partiel corrompu pour forcer un téléchargement neuf
      fi
    else
      echo -e "${YELLOW}   ⚠  Tentative $_try/$_MAX_TRIES — erreur curl${NC}"
      rm -f "$ZIP"
      [[ $_try -lt $_MAX_TRIES ]] && sleep $((2 ** _try))
    fi
  done

  if [[ "$_dl_ok" == false ]]; then
    echo -e "${RED}❌ $pair — téléchargement échoué après $_MAX_TRIES tentatives${NC}"
    rm -f "$ZIP"
    ((failed++)) || true
    continue
  fi

  rm -rf "$EXTRACT"
  mkdir -p "$EXTRACT"
  if ! unzip -q "$ZIP" -d "$EXTRACT"; then
    echo -e "${RED}❌ $pair — extraction échouée${NC}"
    rm -f "$ZIP"; rm -rf "$EXTRACT"
    ((failed++)) || true
    continue
  fi
  rm -f "$ZIP"

  # Le zip peut contenir un sous-dossier racine — on l'aplatit
  inner=$(ls "$EXTRACT" 2>/dev/null | head -1)
  if [[ -n "$inner" && -d "$EXTRACT/$inner" && "$inner" != "model" ]]; then
    EXTRACT_ROOT="$EXTRACT/$inner"
  else
    EXTRACT_ROOT="$EXTRACT"
  fi

  # Vérifie que le modèle CT2 est bien là
  if [[ ! -f "$EXTRACT_ROOT/model/model.bin" ]]; then
    echo -e "${RED}❌ $pair — structure inattendue (model/model.bin absent)${NC}"
    ls -la "$EXTRACT_ROOT/" || true
    rm -rf "$EXTRACT"
    ((failed++)) || true
    continue
  fi

  # Localise le fichier tokenizer (nom variable selon le modèle)
  SPM_SRC=""
  for _name in sentencepiece.model bpe.model source.spm tok.model; do
    if [[ -f "$EXTRACT_ROOT/$_name" ]]; then
      SPM_SRC="$EXTRACT_ROOT/$_name"
      break
    fi
  done
  if [[ -z "$SPM_SRC" ]]; then
    echo -e "${RED}❌ $pair — tokenizer introuvable (sentencepiece.model / bpe.model manquant)${NC}"
    ls -la "$EXTRACT_ROOT/" || true
    rm -rf "$EXTRACT"
    ((failed++)) || true
    continue
  fi

  mkdir -p "$OUT_DIR"
  cp -r "$EXTRACT_ROOT/model" "$OUT_DIR/"
  cp "$SPM_SRC" "$OUT_DIR/sentencepiece.model"
  [[ -f "$EXTRACT_ROOT/metadata.json" ]] && cp "$EXTRACT_ROOT/metadata.json" "$OUT_DIR/"
  touch "$OUT_DIR/.gitkeep"
  rm -rf "$EXTRACT"

  size=$(du -sh "$OUT_DIR" | cut -f1)
  echo -e "${GREEN}✅ $pair installé ($size)${NC}"
  ((ok++)) || true
  echo ""
done

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════"
echo -e "${GREEN}✅ Installés   : $ok${NC}"
[[ $skipped -gt 0 ]] && echo -e "${BLUE}⏭  Déjà présents : $skipped${NC}"
[[ $unavailable -gt 0 ]] && echo -e "${YELLOW}⚠  Non disponibles dans Argos : $unavailable${NC}"
[[ $failed -gt 0 ]]      && echo -e "${RED}❌ Échecs : $failed${NC}"

[[ $failed -gt 0 ]] && exit 1 || exit 0
