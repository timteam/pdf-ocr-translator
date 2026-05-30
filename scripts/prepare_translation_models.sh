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

# ─── Cache persistant des packages de conversion ────────────────────────────
# PKGS_DIR persiste entre les builds pour éviter de re-télécharger ctranslate2,
# torch et leurs dépendances à chaque fois (~500 MB+ sinon).
# Un hash des requirements détecte automatiquement quand une réinstallation
# est nécessaire (changement de version, --clean).
CACHE_BASE="${SCRIPT_DIR}/../.ct2_cache"
PKGS_DIR="${CACHE_BASE}/pkgs"
PIP_CACHE_DIR="${CACHE_BASE}/pip"
PKGS_HASH_FILE="${CACHE_BASE}/pkgs.hash"
# Cache des modèles HuggingFace (blobs LFS, par fichier avec hash SHA-256).
# Pointe vers .ct2_cache/hf/ plutôt que ~/.cache/huggingface/ pour :
#   - Rendre le cache visible et local au projet
#   - Permettre la reprise fichier par fichier en cas d'interruption
#   - Seuls les fichiers avec un hash LFS connu sur le dépôt sont mis en cache ;
#     les autres sont re-téléchargés systématiquement.
HF_CACHE_DIR="${CACHE_BASE}/hf"
PIP_PYZ=""

# Empreinte des requirements : toute modification force une réinstallation
_pkgs_hash() {
  local py_ver
  py_ver=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null || echo "?")
  printf '%s\n' \
    "py=${py_ver}" \
    "ctranslate2" \
    "transformers>=4.40,<5.5" \
    "huggingface_hub>=0.20" \
    "sentencepiece" \
    "torch-cpu" \
  | md5sum | cut -d' ' -f1
}

setup_packages() {
  mkdir -p "$PKGS_DIR" "$PIP_CACHE_DIR"

  local current_hash
  current_hash=$(_pkgs_hash)

  # ── Vérifier la validité du cache ────────────────────────────────────────────
  if [[ "$CLEAN" == false && -f "$PKGS_HASH_FILE" \
        && "$(cat "$PKGS_HASH_FILE")" == "$current_hash" ]]; then
    if PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2, torch" 2>/dev/null; then
      local ct2_ver torch_ver
      ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "?")
      torch_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "?")
      echo "→ Packages en cache : ctranslate2 $ct2_ver / torch $torch_ver"
      echo "  (passer --clean pour forcer la réinstallation)"
      echo ""
      return 0
    fi
    echo "→ Cache invalide (import échoué) — réinstallation..."
    rm -f "$PKGS_HASH_FILE"
  fi

  if [[ "$CLEAN" == true ]]; then
    echo "→ --clean : invalidation du cache packages"
    rm -rf "$PKGS_DIR" && mkdir -p "$PKGS_DIR"
    rm -f "$PKGS_HASH_FILE"
  fi

  # ── Installation ─────────────────────────────────────────────────────────────
  PIP_PYZ=$(mktemp /tmp/pip_XXXXXXXX.pyz)

  echo "→ Téléchargement de pip bootstrap..."
  curl -fL --progress-bar "https://bootstrap.pypa.io/pip/pip.pyz" -o "$PIP_PYZ"
  echo ""

  echo "→ Installation des dépendances (ctranslate2, transformers, huggingface_hub, sentencepiece)..."
  echo "  (~2-5 min à la première installation, puis depuis le cache pip)"
  # transformers<5.5 : évite regex>=2025.10.22 (n'existe pas sur PyPI).
  # sacremoses supprimé : MarianTokenizer utilise SentencePiece directement.
  python3 "$PIP_PYZ" install \
    ctranslate2 \
    "transformers>=4.40,<5.5" \
    "huggingface_hub>=0.20" \
    sentencepiece \
    --target "$PKGS_DIR" \
    --cache-dir "$PIP_CACHE_DIR"

  _install_torch || {
    echo "❌ Impossible d'installer torch — conversion abandonnée."
    echo "   Workaround : sudo pip3 install torch --index-url https://download.pytorch.org/whl/cpu"
    echo "   Puis relancer ce script."
    exit 1
  }

  # ── Sanity check ─────────────────────────────────────────────────────────────
  local ct2_ver torch_ver
  ct2_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2; print(ctranslate2.__version__)" 2>/dev/null || echo "")
  torch_ver=$(PYTHONPATH="$PKGS_DIR" python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")

  if [[ -z "$ct2_ver" || -z "$torch_ver" ]]; then
    echo ""
    echo "❌ Import check échoué :"
    [[ -z "$ct2_ver" ]] && echo "   ctranslate2 non importable"
    [[ -z "$torch_ver" ]] && echo "   torch non importable"
    PYTHONPATH="$PKGS_DIR" python3 -c "import ctranslate2, torch" 2>&1 | head -5
    exit 1
  fi

  echo ""
  echo "→ ctranslate2 $ct2_ver / torch $torch_ver prêts"
  echo "$current_hash" > "$PKGS_HASH_FILE"
  echo ""
}

# ─── Installation de torch avec fallback PyPI ─────────────────────────────────
# PyTorch héberge ses wheels CPU sur download-r2.pytorch.org (Cloudflare R2).
# Si ce CDN est inaccessible, fallback sur PyPI avec --no-deps pour éviter
# ~1.5 GB de libs CUDA (nvidia-cudnn, nvidia-cusparselt, cuda-toolkit…)
# inutiles en mode CPU. Les vraies dépendances CPU de torch (filelock, jinja2,
# fsspec, sympy, mpmath, networkx, typing-extensions) sont déjà installées par
# le premier pip (ctranslate2 + transformers les tirent en transitifs).
_install_torch() {
  if PYTHONPATH="$PKGS_DIR" python3 -c "import torch" 2>/dev/null; then
    echo "→ torch déjà disponible — installation ignorée"
    return 0
  fi

  echo "→ Installation de torch CPU (tentative 1/2 : PyTorch WHL ~200 MB)..."
  if python3 "$PIP_PYZ" install torch \
      --index-url https://download.pytorch.org/whl/cpu \
      --target "$PKGS_DIR" \
      --cache-dir "$PIP_CACHE_DIR"; then
    return 0
  fi

  echo ""
  echo "⚠  CDN PyTorch (download-r2.pytorch.org) inaccessible."
  echo "→ Tentative 2/2 : PyPI + --no-deps (~532 MB, sans libs CUDA)..."
  python3 "$PIP_PYZ" install torch \
    --no-deps \
    --target "$PKGS_DIR" \
    --cache-dir "$PIP_CACHE_DIR"
}

cleanup_packages() {
  [[ -n "$PIP_PYZ" && -f "$PIP_PYZ" ]] && rm -f "$PIP_PYZ"
}
_on_interrupt() {
  echo ""
  echo "⚠  Interruption (Ctrl+C) — arrêt."
  echo "   Téléchargements partiels conservés dans .ct2_cache/hf/"
  echo "   Relancez le script pour reprendre depuis le dernier modèle non converti."
  exit 130
}
trap cleanup_packages EXIT
trap _on_interrupt INT TERM

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
import sys, os, glob, shutil, traceback, time

hf_id, out_dir = sys.argv[1], sys.argv[2]

# Timeout socket : 60s sans données → exception (au lieu de freeze infini).
# HF_HUB_DOWNLOAD_TIMEOUT est lu par huggingface_hub avant toute requête.
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")

_MAX_RETRIES = 4
_RETRY_WAITS = (5, 15, 30, 60)   # secondes entre tentatives

def _download_with_retry(fn, label):
    """Appelle fn() jusqu'à _MAX_RETRIES fois, avec backoff exponentiel."""
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            return fn()
        except KeyboardInterrupt:
            raise
        except Exception as exc:
            if attempt == _MAX_RETRIES:
                raise RuntimeError(f"{label} : échec après {_MAX_RETRIES} tentatives — {exc}") from exc
            wait = _RETRY_WAITS[attempt - 1]
            print(f"  ⚠  {label} (tentative {attempt}/{_MAX_RETRIES}) : {exc}", flush=True)
            print(f"     Retry dans {wait}s…", flush=True)
            time.sleep(wait)

try:
    import ctranslate2
    from huggingface_hub import HfApi, hf_hub_download

    token = os.environ.get("HF_TOKEN") or None
    api = HfApi()

    # 1. Lister les fichiers du dépôt (un seul appel API léger).
    print(f"  Fichiers {hf_id}…", flush=True)
    all_files = _download_with_retry(
        lambda: sorted(api.list_repo_files(repo_id=hf_id, token=token)),
        f"list_repo_files({hf_id})",
    )
    print(f"  {len(all_files)} fichier(s) à télécharger", flush=True)

    # 2. Téléchargement séquentiel fichier par fichier.
    #    hf_hub_download() gère son propre cache (HF_HOME) : si le fichier est
    #    déjà en cache et intact, il est retourné instantanément sans I/O réseau.
    #    On évite ThreadPoolExecutor (snapshot_download) dont les workers peuvent
    #    se bloquer indéfiniment sur un socket silencieux.
    model_dir = None
    for i, filename in enumerate(all_files, 1):
        local_path = _download_with_retry(
            lambda fn=filename: hf_hub_download(repo_id=hf_id, filename=fn, token=token),
            f"[{i}/{len(all_files)}] {filename}",
        )
        if model_dir is None:
            model_dir = os.path.dirname(local_path)
        print(f"  [{i}/{len(all_files)}] {filename} ✓", flush=True)

    # 3. Vérification des poids (snapshot parfois incomplet si blob LFS manquant).
    _WEIGHT_FILES = ("model.safetensors", "pytorch_model.bin", "model.pt")
    if not any(os.path.exists(os.path.join(model_dir, f)) for f in _WEIGHT_FILES):
        raise RuntimeError(
            f"Snapshot incomplet : aucun fichier de poids dans {model_dir}\n"
            f"  Cherché : {', '.join(_WEIGHT_FILES)}"
        )

    # 4. Sélection du convertisseur selon le format du modèle.
    #    Les modèles Helsinki-NLP sur HuggingFace sont en format PyTorch
    #    (config.json + pytorch_model.bin / model.safetensors).
    #    OpusMTConverter attend le format Marian original (decoder.yml + model.npz).
    #    TransformersConverter gère le format HuggingFace PyTorch.
    print(f"  Conversion CTranslate2 INT8…", flush=True)
    if os.path.exists(os.path.join(model_dir, "decoder.yml")):
        converter = ctranslate2.converters.OpusMTConverter(model_dir)
    elif hasattr(ctranslate2.converters, "TransformersConverter"):
        converter = ctranslate2.converters.TransformersConverter(
            model_dir, low_cpu_mem_usage=True
        )
    else:
        available = sorted(
            x for x in dir(ctranslate2.converters)
            if "Converter" in x and not x.startswith("_")
        )
        raise RuntimeError(
            f"TransformersConverter introuvable dans ctranslate2.converters.\n"
            f"Disponibles : {available}"
        )

    converter.convert(out_dir, quantization="int8", force=True)
    print(f"  model.bin + shared_vocabulary.json générés", flush=True)

    # 5. Copie des fichiers SPM (déjà dans le cache — pas de reconnexion réseau).
    print(f"  Tokenizer SPM…", flush=True)
    copied = []
    for pattern in ("*.spm", "*.model"):
        for f in glob.glob(os.path.join(model_dir, pattern)):
            dst = os.path.join(out_dir, os.path.basename(f))
            if not os.path.exists(dst):
                shutil.copy(f, dst)
                copied.append(os.path.basename(f))
    print(f"  Copiés : {', '.join(copied)}" if copied else f"  SPM déjà présents", flush=True)

    # 6. Vérification finale
    if not os.path.exists(os.path.join(out_dir, "model.bin")):
        raise RuntimeError(f"model.bin absent dans {out_dir} après conversion")

    size = sum(os.path.getsize(os.path.join(out_dir, f))
               for f in os.listdir(out_dir) if not f.startswith('.')) / 1024 / 1024
    print(f"  ✓ {out_dir} ({size:.0f} MB)", flush=True)

except KeyboardInterrupt:
    print("\n  Interruption (Ctrl+C)", file=sys.stderr, flush=True)
    sys.exit(130)
except Exception as e:
    traceback.print_exc(file=sys.stderr)
    print(f"  ✗ {hf_id} : {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  # Capturer le code de sortie avant rm -f :
  # Quand convert_model est appelée dans un `if`, bash suspend set -e à l'intérieur
  # de la fonction. Sans cette capture, rm -f (exit 0) masque l'échec de python3.
  local py_exit=0
  mkdir -p "$HF_CACHE_DIR"
  PYTHONPATH="$PKGS_DIR" HF_HOME="$HF_CACHE_DIR" python3 "$py_script" "$hf_id" "$dest" || py_exit=$?
  rm -f "$py_script"
  return $py_exit
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
VERBOSE=false
LIST_ONLY=false
SMALL_MODE=false
CLEAN=false
CLEAN_DOWNLOAD=false
DEST_DIR="$DEFAULT_DEST"
HF_TOKEN_ARG=""
MODELS_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -l|--list)    LIST_ONLY=true; shift ;;
    -s|--small)   SMALL_MODE=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    --clean)           CLEAN=true; shift ;;
    --clean-download)  CLEAN_DOWNLOAD=true; shift ;;
    --models)
      [[ -z "${2:-}" || "${2:-}" == --* ]] && { echo "❌ --models requiert une liste de clés (ex: --models ja-en,en-ROMANCE)"; exit 1; }
      MODELS_FILTER="$2"; shift 2 ;;
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
elif [[ -n "$MODELS_FILTER" ]]; then
  IFS=',' read -ra MODELS_TO_DO <<< "$MODELS_FILTER"
  # Valider chaque clé
  for _k in "${MODELS_TO_DO[@]}"; do
    if [[ -z "${MODEL_HF[$_k]+x}" ]]; then
      echo "❌ Clé inconnue : '$_k'"
      echo "   Clés valides : ${ALL_MODELS[*]}"
      exit 1
    fi
  done
  echo "Sélection : ${#MODELS_TO_DO[@]} modèles (${MODELS_TO_DO[*]})"
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

# ─── Migration one-shot : ancien cache système → cache projet ────────────────
# Si le cache HF projet est vide mais que ~/.cache/huggingface/hub/ contient
# des modèles, on les copie pour ne pas perdre les téléchargements partiels.
_SYS_HF_HUB="$HOME/.cache/huggingface/hub"
if [[ -d "$_SYS_HF_HUB" && ! -d "$HF_CACHE_DIR/hub" ]]; then
  echo "→ Migration du cache HuggingFace système → projet (.ct2_cache/hf/)..."
  mkdir -p "$HF_CACHE_DIR"
  cp -a "$_SYS_HF_HUB" "$HF_CACHE_DIR/hub"
  echo "   ✓ Migration terminée — les téléchargements partiels sont préservés"
  echo ""
fi

# ─── Cache de téléchargement HuggingFace ─────────────────────────────────────
# --clean-download : vide uniquement le cache des blobs HF (.ct2_cache/hf/).
# Les packages de conversion (torch, transformers…) sont conservés.
if [[ "$CLEAN_DOWNLOAD" == true ]]; then
  if [[ -d "$HF_CACHE_DIR" ]]; then
    echo "→ --clean-download : suppression du cache HF ($HF_CACHE_DIR)..."
    rm -rf "$HF_CACHE_DIR"
    echo "   ✓ Cache vidé — les modèles seront re-téléchargés depuis HuggingFace"
  else
    echo "→ --clean-download : cache HF déjà vide"
  fi
  echo ""
fi

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
  echo "[$COUNT/$TOTAL] $key (${MODEL_HF[$key]:-?})..."

  if convert_model "$key" "$out_dir"; then
    DONE=$((DONE + 1))
    _print_bar "$DONE" "$TOTAL" "$key ✓"
  else
    _exit=$?
    # Ctrl+C (130) ou segfault provoqué par l'interruption (139) → stop immédiat
    if [[ $_exit -eq 130 || $_exit -eq 139 ]]; then
      _on_interrupt
    fi
    echo "  ✗ $key — échec (code $_exit)"
    FAILED+=("$key")
    # Supprime les fichiers générés mais conserve le répertoire + .gitkeep
    # (Flutter exige que les répertoires déclarés dans pubspec.yaml existent)
    find "$out_dir" -type f ! -name '.gitkeep' -delete 2>/dev/null || true
    mkdir -p "$out_dir" && touch "$out_dir/.gitkeep"
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
