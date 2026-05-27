#!/bin/bash
# Télécharge les wheels pip requis pour le build snap.
# Compatible macOS et Linux. Télécharge toujours des wheels Linux x86_64 (cp312)
# pour être utilisables dans le container LXC snapcraft (core26 = Python 3.12).
# À exécuter une fois avant build-snap.sh ; les wheels sont réutilisés entre builds.
#
# Intégrité :
#   - paddlepaddle : SHA256 vérifié contre l'API PyPI après téléchargement curl
#   - autres packages : pip vérifie automatiquement les SHA256 depuis l'index PyPI
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHEELS_DIR="$SCRIPT_DIR/../wheels"
mkdir -p "$WHEELS_DIR"

PIP="python3 -m pip"

if ! python3 -m pip --version &>/dev/null; then
  echo "❌ python3 -m pip non disponible."
  echo "   macOS : brew install python  ou  python3 -m ensurepip"
  echo "   Linux : sudo apt install python3-pip"
  exit 1
fi

sha256_verify() {
  local file="$1" expected="$2" label="$3"
  local actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | cut -d' ' -f1)
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  else
    echo "   ⚠️  sha256sum/shasum non disponible, vérification de $label ignorée"
    return 0
  fi
  if [ "$actual" != "$expected" ]; then
    echo "❌ Vérification SHA256 échouée pour $label"
    echo "   Attendu : $expected"
    echo "   Obtenu  : $actual"
    return 1
  fi
  echo "   ✅ SHA256 vérifié : $label"
}

echo "⬇️  Téléchargement des wheels Python pour le snap..."
echo "   Plateforme cible : linux x86_64 / Python 3.12 (core26)"
echo "   Destination      : $WHEELS_DIR"
echo ""

# ---------------------------------------------------------------------------
# paddlepaddle : ~185 MB — pip download ne supporte pas la reprise partielle.
# Version épinglée pour garantir la reproductibilité des builds.
# On résout l'URL et le SHA256 via l'API PyPI (version fixe), puis on
# télécharge avec curl -C - (resume HTTP Range) avec retry automatique.
# Pour mettre à jour : changer PADDLE_VERSION et supprimer le wheel existant.
# ---------------------------------------------------------------------------
PADDLE_VERSION="3.3.1"

# Si un wheel complet pour cette version est déjà présent, on saute la
# résolution réseau et le téléchargement.
EXISTING=$(ls "$WHEELS_DIR"/paddlepaddle-${PADDLE_VERSION}-cp312-*x86_64*.whl 2>/dev/null | head -1)
if [ -n "$EXISTING" ]; then
  echo "   ✅ paddlepaddle ${PADDLE_VERSION} déjà présent : $(basename "$EXISTING")"
else
  echo "→ Résolution de paddlepaddle ${PADDLE_VERSION} via l'API PyPI..."

  read -r PADDLE_URL PADDLE_SIZE PADDLE_SHA256 PADDLE_FILE_NAME <<< "$(python3 - <<EOF
import sys, json
try:
    from urllib.request import urlopen
    with urlopen("https://pypi.org/pypi/paddlepaddle/${PADDLE_VERSION}/json") as r:
        d = json.load(r)
except Exception as e:
    print(f"Erreur API PyPI: {e}", file=sys.stderr)
    sys.exit(1)
files = d.get("urls", [])
wheel = next(
    (f for f in files if "cp312" in f["filename"] and "x86_64" in f["filename"]),
    None,
)
if not wheel:
    print("Aucun wheel cp312/x86_64 trouvé", file=sys.stderr)
    sys.exit(1)
print(wheel["url"], wheel.get("size", 0), wheel["digests"]["sha256"], wheel["filename"])
EOF
)"

  if [ -z "$PADDLE_URL" ]; then
    echo "❌ Impossible de résoudre l'URL paddlepaddle ${PADDLE_VERSION} depuis PyPI."
    exit 1
  fi

  PADDLE_DEST="$WHEELS_DIR/$PADDLE_FILE_NAME"
  echo "   URL   : $PADDLE_URL"
  echo "   SHA256: $PADDLE_SHA256"
  echo "   Taille: $(( PADDLE_SIZE / 1048576 )) MB"

  if [ -f "$PADDLE_DEST" ] && [ "$PADDLE_SIZE" -gt 0 ]; then
    ACTUAL_SIZE=$(wc -c < "$PADDLE_DEST")
    if [ "$ACTUAL_SIZE" -eq "$PADDLE_SIZE" ]; then
      echo "   Fichier complet, vérification de l'intégrité..."
      sha256_verify "$PADDLE_DEST" "$PADDLE_SHA256" "paddlepaddle"
    else
      echo "   Fichier partiel ($(( ACTUAL_SIZE / 1048576 )) MB / $(( PADDLE_SIZE / 1048576 )) MB), reprise..."
      curl -C - \
        --retry 15 --retry-delay 15 --retry-all-errors \
        --connect-timeout 30 \
        -L --progress-bar \
        -o "$PADDLE_DEST" "$PADDLE_URL"
      sha256_verify "$PADDLE_DEST" "$PADDLE_SHA256" "paddlepaddle"
    fi
  else
    curl -C - \
      --retry 15 --retry-delay 15 --retry-all-errors \
      --connect-timeout 30 \
      -L --progress-bar \
      -o "$PADDLE_DEST" "$PADDLE_URL"
    sha256_verify "$PADDLE_DEST" "$PADDLE_SHA256" "paddlepaddle"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Dépendances transitives de paddlepaddle + autres packages.
#
# paddlepaddle est inclus dans la liste : pip le retrouve via --find-links
# (wheel déjà présent dans WHEELS_DIR) et télécharge uniquement ses
# dépendances manquantes (protobuf, numpy, httpx, Pillow, safetensors…).
# Les SHA256 des packages téléchargés par pip sont vérifiés automatiquement
# par pip contre l'index PyPI — aucune action supplémentaire requise.
# ---------------------------------------------------------------------------
echo "→ Dépendances transitives + autres packages..."
$PIP download \
  --no-cache-dir \
  --only-binary :all: \
  --find-links "$WHEELS_DIR" \
  --platform manylinux_2_17_x86_64 \
  --platform manylinux2014_x86_64 \
  --python-version 312 \
  --implementation cp \
  --abi cp312 \
  --dest "$WHEELS_DIR" \
  paddlepaddle \
  paddleocr \
  ctranslate2 \
  sentencepiece \
  fasttext-wheel

echo ""
echo "✅ Wheels téléchargés :"
ls -lh "$WHEELS_DIR/"*.whl 2>/dev/null | awk '{print "   " $5 "\t" $9}' || true
echo ""
echo "Total : $(du -sh "$WHEELS_DIR/" | cut -f1)"
