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

# ── Modèles de traduction OPUS-MT ────────────────────────────────────────────
# Les modèles doivent être dans flutter_app/assets/translation_models/ pour
# être bundlés par Flutter (déclarés dans pubspec.yaml).
# Si absents, la traduction est désactivée mais l'OCR fonctionne.
echo -e "${YELLOW}🔍 Vérification des modèles de traduction...${NC}"
FLUTTER_MODELS_DIR="flutter_app/assets/translation_models"
MODELS_COUNT=$(find "$FLUTTER_MODELS_DIR" -name "model.bin" 2>/dev/null | wc -l)

if [[ $MODELS_COUNT -eq 0 ]]; then
  echo -e "${YELLOW}📥 Aucun modèle de traduction trouvé.${NC}"
  echo -e "${YELLOW}   (~1-3 h au premier build selon la connexion, 24 modèles × ~200 MB)${NC}"
  echo ""

  # ── Token HuggingFace ────────────────────────────────────────────────────────
  # Cache local dans .hf_token (gitignore, chmod 600).
  # Priorité : cache > $HF_TOKEN > prompt interactif.
  HF_TOKEN_CACHE=".hf_token"
  HF_TOKEN_FOR_BUILD=""
  _hf_mask() { local t="$1"; echo "${t:0:8}****"; }

  if [[ -t 0 ]]; then
    # ── Mode interactif ──────────────────────────────────────────────────────
    if [[ -f "$HF_TOKEN_CACHE" ]]; then
      _CACHED="$(< "$HF_TOKEN_CACHE")"
      echo -e "${BLUE}🔑 Token HuggingFace en cache : $(_hf_mask "$_CACHED")${NC}"
      echo -e "   ${BLUE}[Entrée]${NC} Réutiliser   ${BLUE}[n]${NC} Nouveau   ${BLUE}[s]${NC} Supprimer   ${BLUE}[i]${NC} Ignorer"
      read -r -p "   > " _HF_CHOICE
      case "${_HF_CHOICE,,}" in
        n*)
          read -r -p "   Nouveau token hf_... : " _NEW_TOKEN
          if [[ -n "$_NEW_TOKEN" ]]; then
            printf '%s' "$_NEW_TOKEN" > "$HF_TOKEN_CACHE"; chmod 600 "$HF_TOKEN_CACHE"
            HF_TOKEN_FOR_BUILD="$_NEW_TOKEN"
            echo -e "${GREEN}   ✓ Token mis à jour${NC}"
          else
            HF_TOKEN_FOR_BUILD="$_CACHED"
            echo -e "${BLUE}   Token inchangé${NC}"
          fi ;;
        s*)
          rm -f "$HF_TOKEN_CACHE"
          echo -e "${YELLOW}   Token supprimé du cache${NC}"
          read -r -p "   Nouveau token (ou Entrée pour ignorer) : " _NEW_TOKEN
          if [[ -n "$_NEW_TOKEN" ]]; then
            printf '%s' "$_NEW_TOKEN" > "$HF_TOKEN_CACHE"; chmod 600 "$HF_TOKEN_CACHE"
            HF_TOKEN_FOR_BUILD="$_NEW_TOKEN"
            echo -e "${GREEN}   ✓ Nouveau token sauvegardé${NC}"
          fi ;;
        i*)
          echo -e "${YELLOW}   Token ignoré${NC}" ;;
        *)  # Entrée ou 'r' : réutiliser
          HF_TOKEN_FOR_BUILD="$_CACHED"
          echo -e "${GREEN}   ✓ Token réutilisé${NC}" ;;
      esac

    elif [[ -n "${HF_TOKEN:-}" ]]; then
      HF_TOKEN_FOR_BUILD="$HF_TOKEN"
      echo -e "${BLUE}🔑 \$HF_TOKEN détecté ($(_hf_mask "$HF_TOKEN"))${NC}"
      read -r -p "   Sauvegarder en cache local (.hf_token) pour les prochains builds ? [O/n] : " _SAVE
      if [[ "${_SAVE,,}" != n* ]]; then
        printf '%s' "$HF_TOKEN" > "$HF_TOKEN_CACHE"; chmod 600 "$HF_TOKEN_CACHE"
        echo -e "${GREEN}   ✓ Token sauvegardé dans $HF_TOKEN_CACHE${NC}"
      fi

    else
      echo -e "${BLUE}🔑 Token HuggingFace (optionnel — évite le rate-limiting sur 24 téléchargements)${NC}"
      echo -e "   Créer un token Read sur https://huggingface.co/settings/tokens"
      read -r -p "   Token hf_... (Entrée pour ignorer) : " _NEW_TOKEN
      if [[ -n "$_NEW_TOKEN" ]]; then
        printf '%s' "$_NEW_TOKEN" > "$HF_TOKEN_CACHE"; chmod 600 "$HF_TOKEN_CACHE"
        HF_TOKEN_FOR_BUILD="$_NEW_TOKEN"
        echo -e "${GREEN}   ✓ Token sauvegardé dans $HF_TOKEN_CACHE${NC}"
      else
        echo -e "${YELLOW}   Aucun token — les modèles publics fonctionnent sans.${NC}"
      fi
    fi

  else
    # ── Mode non-interactif (CI) : cache ou $HF_TOKEN en silence ────────────
    if [[ -f "$HF_TOKEN_CACHE" ]]; then
      HF_TOKEN_FOR_BUILD="$(< "$HF_TOKEN_CACHE")"
      echo -e "${BLUE}🔑 Token HuggingFace : .hf_token (cache)${NC}"
    elif [[ -n "${HF_TOKEN:-}" ]]; then
      HF_TOKEN_FOR_BUILD="$HF_TOKEN"
      echo -e "${BLUE}🔑 Token HuggingFace : \$HF_TOKEN${NC}"
    fi
  fi

  echo ""
  echo -e "${YELLOW}   Génération des modèles en cours...${NC}"
  _HF_ARGS=()
  [[ -n "$HF_TOKEN_FOR_BUILD" ]] && _HF_ARGS=("--hf-token" "$HF_TOKEN_FOR_BUILD")
  if ./scripts/prepare_translation_models.sh "${_HF_ARGS[@]}" "$FLUTTER_MODELS_DIR"; then
    MODELS_COUNT=$(find "$FLUTTER_MODELS_DIR" -name "model.bin" 2>/dev/null | wc -l)
    echo -e "${GREEN}✅ $MODELS_COUNT modèle(s) généré(s)${NC}"
  else
    echo -e "${YELLOW}⚠️  Génération échouée — build sans traduction (OCR OK)${NC}"
  fi
else
  echo -e "${GREEN}✅ $MODELS_COUNT modèle(s) CTranslate2 trouvé(s)${NC}"
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
elif find lib assets pubspec.yaml -newer "$BUNDLE" -print -quit 2>/dev/null | grep -q .; then
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
