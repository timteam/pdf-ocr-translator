#!/bin/bash
# Snap Build Script for PDF OCR Translator
#
# Usage:
#   ./build-snap.sh           — build incrémental (rapide, recommandé)
#   ./build-snap.sh --clean   — rebuild complet depuis zéro (lent, ~15 min)
#                               Obligatoire après modification de stage-packages

set -e

CLEAN=false
for arg in "$@"; do
  [[ "$arg" == "--clean" ]] && CLEAN=true
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "📦 Building PDF OCR Translator Snap Package"
echo "==========================================="
$CLEAN && echo -e "${YELLOW}Mode : rebuild complet (--clean)${NC}" \
       || echo -e "${BLUE}Mode : build incrémental${NC}"

if ! command -v snapcraft &> /dev/null; then
    echo -e "${RED}❌ Snapcraft is not installed!${NC}"
    echo "sudo snap install snapcraft --classic"
    exit 1
fi
echo -e "${BLUE}✅ Snapcraft found: $(snapcraft --version)${NC}"

BUILD_DIR="./snap-builds"
mkdir -p "$BUILD_DIR"

# ── Modèle FastText LID (asset Flutter, ~917 KB) ─────────────────────────────
echo -e "${YELLOW}🔍 Vérification du modèle FastText LID...${NC}"
./scripts/download_fasttext_model.sh

# ── Wheels Python ────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔍 Vérification des wheels Python...${NC}"
./scripts/download_pip_wheels.sh

# ── Modèles de traduction Opus-MT (Argos) ────────────────────────────────────
# Les modèles sont dans flutter_app/assets/translation_models/{src}-{tgt}/
# Structure : model/model.bin + sentencepiece.model
# Si absents, la traduction est désactivée mais l'OCR fonctionne.
echo -e "${YELLOW}🔍 Vérification des modèles de traduction Opus-MT…${NC}"
FLUTTER_MODELS_DIR="flutter_app/assets/translation_models"
_SKIP_MODELS=false

# Compte les modèles déjà présents
_n_present=0
for _d in "$FLUTTER_MODELS_DIR"/*/; do
  [[ -f "$_d/model/model.bin" ]] && ((_n_present++)) || true
done

if [[ $_n_present -gt 0 ]]; then
  echo -e "${GREEN}✅ $_n_present modèle(s) Opus-MT présent(s)${NC}"

  if [[ -t 0 ]]; then
    echo -e "${BLUE}   Modèles de traduction :${NC}"
    echo -e "   ${BLUE}[Entrée]${NC} Garder en l'état ✅"
    echo -e "   ${BLUE}[m]${NC}      Télécharger les manquants"
    echo -e "   ${BLUE}[r]${NC}      Re-télécharger tous (--clean)"
    echo -e "   ${BLUE}[pg]${NC}     Purger — build OCR uniquement"
    echo ""
    read -r -p "   > " _MC
    case "${_MC,,}" in
      m*)
        echo -e "${GREEN}   → Téléchargement des modèles manquants${NC}"
        ;;
      r*)
        echo -e "${GREEN}   → Re-téléchargement complet${NC}"
        ;;
      pg*)
        find "$FLUTTER_MODELS_DIR" -name "model.bin" -delete 2>/dev/null || true
        echo -e "${GREEN}   ✓ Modèles purgés — build OCR uniquement${NC}"
        _SKIP_MODELS=true
        ;;
      *)
        _SKIP_MODELS=true
        ;;
    esac
  else
    _SKIP_MODELS=true
  fi
else
  echo -e "${YELLOW}   Aucun modèle présent${NC}"
  echo ""

  if [[ -t 0 ]]; then
    echo -e "${BLUE}   Modèles Opus-MT (Argos, ~50-100 Mo/paire) :${NC}"
    echo -e "   ${BLUE}[Entrée]${NC} Télécharger toutes les paires"
    echo -e "   ${BLUE}[s]${NC}      Sauter — build OCR uniquement"
    echo ""
    read -r -p "   > " _MC
    case "${_MC,,}" in
      s*)
        echo -e "${YELLOW}   → Build OCR uniquement (traduction désactivée)${NC}"
        _SKIP_MODELS=true
        ;;
      *)
        echo -e "${GREEN}   → Téléchargement des modèles Opus-MT${NC}"
        ;;
    esac
  else
    echo -e "${YELLOW}📥 Modèles absents — téléchargement automatique${NC}"
  fi
fi

if [[ "$_SKIP_MODELS" == false ]]; then
  _CLEAN_FLAG=""
  [[ "${_MC,,}" == r* ]] && _CLEAN_FLAG="--clean"

  echo ""
  # Relances automatiques si des modèles échouent (réseau instable)
  _MAX_BUILD_TRIES=3
  _build_try=0
  while [[ $_build_try -lt $_MAX_BUILD_TRIES ]]; do
    ((_build_try++)) || true
    ./scripts/prepare_translation_models.sh $_CLEAN_FLAG && break
    _n_missing=0
    for _d in "$FLUTTER_MODELS_DIR"/*/; do
      [[ ! -f "$_d/model/model.bin" ]] && ((_n_missing++)) || true
    done
    if [[ $_n_missing -eq 0 ]]; then break; fi
    if [[ $_build_try -lt $_MAX_BUILD_TRIES ]]; then
      echo -e "${YELLOW}⚠️  $_n_missing modèle(s) manquant(s) — relance $_build_try/$_MAX_BUILD_TRIES dans 5s…${NC}"
      sleep 5
      _CLEAN_FLAG=""  # pas de --clean sur les relances, reprend les partiels
    fi
  done
  _n_ok=0; _n_miss=0
  for _d in "$FLUTTER_MODELS_DIR"/*/; do
    if [[ -f "$_d/model/model.bin" ]]; then ((_n_ok++)) || true
    else ((_n_miss++)) || true; fi
  done
  if [[ $_n_miss -eq 0 ]]; then
    echo -e "${GREEN}✅ $_n_ok modèle(s) Opus-MT prêt(s) — complet${NC}"
  else
    echo -e "${YELLOW}⚠️  $_n_ok prêt(s), $_n_miss manquant(s) — traduction partielle${NC}"
  fi
fi

# ── Flutter build (conditionnel) ─────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
  echo -e "${RED}❌ Snap build requires a Linux host.${NC}"
  exit 1
fi

if ! command -v flutter &> /dev/null; then
    echo -e "${RED}❌ Flutter CLI is not installed!${NC}"
    exit 1
fi

for tool in cmake ninja clang++ pkg-config; do
  if ! command -v "$tool" &> /dev/null; then
    echo -e "${RED}❌ Required build tool missing: $tool${NC}"
    echo "  sudo apt install build-essential cmake ninja-build clang++ pkg-config libgtk-3-dev"
    exit 1
  fi
done

cd flutter_app

if [[ ! -d linux ]]; then
  flutter create --platforms=linux .
fi

BUNDLE="build/linux/x64/release/bundle/pdf_ocr_translator"

# Rebuild Flutter seulement si des sources Dart/pubspec ont changé depuis
# le dernier binaire — évite 3-5 min inutiles à chaque build snap.
NEEDS_FLUTTER_BUILD=false
if [[ ! -f "$BUNDLE" ]]; then
  NEEDS_FLUTTER_BUILD=true
elif find lib assets pubspec.yaml -newer "$BUNDLE" \
        -not -path "assets/translation_models/*" \
        -print -quit 2>/dev/null | grep -q .; then
  NEEDS_FLUTTER_BUILD=true
fi

if $NEEDS_FLUTTER_BUILD; then
  echo -e "${YELLOW}🔨 Flutter sources modifiées — rebuild...${NC}"
  flutter pub get
  flutter build linux --release
else
  echo -e "${GREEN}⚡ Flutter bundle à jour — rebuild ignoré${NC}"
fi

cd ..

# ── Libs bundlées depuis le host (absentes des dépôts Ubuntu 24.04/core24) ───
mkdir -p libs
GLYCIN=/usr/lib/x86_64-linux-gnu/libglycin-2.so.0
if [ ! -f "$GLYCIN" ]; then
  echo -e "${RED}❌ $GLYCIN introuvable — installe : sudo apt install libglycin-2-0${NC}"
  exit 1
fi
cp -f "$GLYCIN" libs/

# ── Snapcraft ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔨 Packaging snap...${NC}"

# --clean : nettoie tout le state snapcraft (parts/stage/prime).
# Nécessaire après modification de stage-packages pour éviter un prime
# incohérent. En build incrémental, snapcraft détecte les changements seul.
# Hash de snapcraft.yaml pour détecter automatiquement un changement de
# stage-packages et avertir l'utilisateur s'il n'a pas passé --clean.
HASH_FILE=".snapcraft_yaml_hash"
CURRENT_HASH=$(sha256sum snapcraft.yaml | cut -d' ' -f1)
if [[ -f "$HASH_FILE" ]]; then
  PREV_HASH=$(cat "$HASH_FILE")
  if [[ "$CURRENT_HASH" != "$PREV_HASH" ]] && ! $CLEAN; then
    echo -e "${YELLOW}⚠️  snapcraft.yaml a changé depuis le dernier build.${NC}"
    echo -e "${YELLOW}   Si tu as modifié des stage-packages, relance avec --clean.${NC}"
  fi
fi

SNAPCRAFT_OK=false

if $CLEAN; then
  echo -e "${YELLOW}🧹 Nettoyage du state snapcraft...${NC}"
  snapcraft clean
  echo -e "${YELLOW}🔨 Build complet...${NC}"
  # Après un clean total, snapcraft (sans sous-commande) reconstruit toutes les parts.
  if snapcraft; then
    SNAPCRAFT_OK=true
  fi
else
  # Build incrémental : snapcraft pack exécute le pipeline complet MAIS saute
  # les parts dont les state files sont intacts. Il faut nettoyer flutter-app
  # pour invalider ses state files — snapcraft pack re-traite ensuite cette
  # seule part (pull→build→stage→prime) puis pack le tout.
  echo -e "${YELLOW}🔄 Invalidation du cache flutter-app...${NC}"
  snapcraft clean flutter-app
  echo -e "${YELLOW}🔨 Packaging snap...${NC}"
  if snapcraft pack; then
    SNAPCRAFT_OK=true
  fi
fi

if $SNAPCRAFT_OK; then
    echo "$CURRENT_HASH" > "$HASH_FILE"
    echo -e "${GREEN}✅ Snap build completed successfully!${NC}"

    if ls *.snap 1> /dev/null 2>&1; then
        mv *.snap "$BUILD_DIR/" 2>/dev/null || true
        echo -e "${GREEN}📁 Snap moved to: $BUILD_DIR${NC}"
        ls -la "$BUILD_DIR/"
    fi

    echo ""
    echo -e "${GREEN}🎉 Snap package ready!${NC}"
    echo -e "${BLUE}Installation :${NC} sudo snap install $BUILD_DIR/*.snap --dangerous"
    echo -e "${BLUE}Connexion    :${NC} sudo snap connect pdf-ocr-translator:gnome-46-2404 gnome-46-2404:gnome-46-2404"
else
    echo -e "${RED}❌ Snap build failed!${NC}"
    exit 1
fi
