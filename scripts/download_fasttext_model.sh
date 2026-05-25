#!/bin/bash
# Télécharge le modèle compact FastText LID (176 langues, ~917 KB)
# À exécuter une fois avant de builder l'application.
set -e

DEST="$(dirname "$0")/../flutter_app/assets/models/lid.176.ftz"
URL="https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz"

if [ -f "$DEST" ]; then
  echo "Modèle déjà présent : $DEST"
  exit 0
fi

echo "Téléchargement du modèle FastText LID…"
curl -L --progress-bar -o "$DEST" "$URL"
echo "Modèle enregistré : $DEST ($(du -sh "$DEST" | cut -f1))"
