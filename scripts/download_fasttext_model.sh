#!/bin/bash
# Télécharge le modèle compact FastText LID (176 langues, ~917 KB)
# et vérifie son authenticité par SHA256.
# À exécuter une fois avant de builder l'application.
set -e

DEST="$(dirname "$0")/../flutter_app/assets/models/lid.176.ftz"
mkdir -p "$(dirname "$DEST")"

# SHA256 du modèle officiel FastText LID compact (lid.176.ftz)
EXPECTED_SHA256="8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83"

sha256_verify() {
  local file="$1"
  local actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | cut -d' ' -f1)
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  else
    echo "⚠️  sha256sum/shasum non disponible, vérification ignorée"
    return 0
  fi
  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    echo "❌ Vérification SHA256 échouée"
    echo "   Attendu : $EXPECTED_SHA256"
    echo "   Obtenu  : $actual"
    return 1
  fi
  echo "✅ SHA256 vérifié : lid.176.ftz"
}

if [ -f "$DEST" ]; then
  echo "Modèle déjà présent : $DEST ($(du -sh "$DEST" | cut -f1))"
  sha256_verify "$DEST"
  exit 0
fi

URLS=(
  "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz"
  "https://huggingface.co/julien-c/fasttext-language-id/resolve/main/lid.176.ftz"
)

download_ok=0
for url in "${URLS[@]}"; do
  echo "Tentative : $url"
  if curl -fL --progress-bar --retry 3 --retry-delay 5 --connect-timeout 30 -o "$DEST" "$url"; then
    if sha256_verify "$DEST"; then
      echo "✅ Modèle enregistré : $DEST ($(du -sh "$DEST" | cut -f1))"
      download_ok=1
      break
    else
      rm -f "$DEST"
      echo "⚠️  Hash invalide, essai suivant..."
    fi
  else
    rm -f "$DEST"
    echo "⚠️  Échec réseau, essai suivant..."
  fi
done

if [ $download_ok -eq 0 ]; then
  echo ""
  echo "❌ Tous les téléchargements ont échoué."
  echo "   Télécharge manuellement lid.176.ftz et place-le dans :"
  echo "   flutter_app/assets/models/lid.176.ftz"
  echo ""
  echo "   SHA256 attendu : $EXPECTED_SHA256"
  echo ""
  echo "   Sources :"
  echo "   - https://fasttext.cc/docs/en/language-identification.html"
  echo "   - https://huggingface.co/julien-c/fasttext-language-id"
  exit 1
fi
