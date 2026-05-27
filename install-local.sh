#!/bin/bash
# ⚠️  SCRIPT DE DÉVELOPPEMENT / TEST UNIQUEMENT
#
# Installe le snap produit localement et établit la connexion au content snap
# GTK3 requise pour que l'application démarre.
#
# Pourquoi cette connexion est nécessaire en local :
#   L'installation avec --dangerous (fichier local) bypass le Snap Store, qui
#   est normalement responsable d'établir les connexions automatiquement.
#   La commande "snap connect" monte le snap gnome-46-2404 (GTK3 + GDK-Pixbuf
#   + libepoxy) dans $SNAP/gnome-platform au moment du "snap run". Sans elle,
#   ce répertoire est vide et l'application ne peut pas démarrer.
#
# En production (installation depuis le Snap Store) :
#   La connexion est établie automatiquement grâce au champ
#   "default-provider: gnome-46-2404" déclaré dans snapcraft.yaml.
#   Ce script n'est alors pas nécessaire.
set -e

SNAP_FILE=$(ls snap-builds/pdf-ocr-translator_*.snap 2>/dev/null | tail -1)

if [ -z "$SNAP_FILE" ]; then
  echo "❌ Aucun snap trouvé dans snap-builds/. Lance d'abord : bash build-snap.sh"
  exit 1
fi

echo "📦 Installation : $SNAP_FILE"
sudo snap install "$SNAP_FILE" --dangerous

# Monte le contenu de gnome-46-2404 (GTK3, GDK-Pixbuf, libepoxy) dans
# $SNAP/gnome-platform au runtime. Requis car --dangerous bypass le Store.
echo "🔗 Connexion du content snap GTK3 (gnome-46-2404)..."
sudo snap connect pdf-ocr-translator:gnome-46-2404 gnome-46-2404:gnome-46-2404

echo "✅ Installé. Lance avec : snap run pdf-ocr-translator"
