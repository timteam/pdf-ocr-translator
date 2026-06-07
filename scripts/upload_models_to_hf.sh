#!/bin/bash
#
# Upload du modèle NLLB-200-distilled-600M (CTranslate2 INT8) vers un dépôt HuggingFace Dataset.
# Compare les SHA-256 locaux avec ceux du dépôt pour n'uploader que le nécessaire.
# Utilise hf_transfer (Rust) pour les transferts — fiable sur les gros fichiers.
#
# Usage :
#   ./scripts/upload_models_to_hf.sh --repo Timteamteem/nllb-ct2 --hf-token hf_...
#   ./scripts/upload_models_to_hf.sh --repo Timteamteem/nllb-ct2 --yes
#
# Prérequis : avoir exécuté prepare_translation_models.sh (installe huggingface_hub)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/../flutter_app/assets/translation_models"
PKGS_DIR="$SCRIPT_DIR/../.ct2_cache/pkgs"
HF_TOKEN_CACHE="$SCRIPT_DIR/../.hf_token"

HF_REPO=""
HF_TOKEN_ARG=""
NON_INTERACTIVE=false
PRESELECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     [[ -z "${2:-}" ]] && { echo "❌ --repo requiert OWNER/REPO"; exit 1; }
                HF_REPO="$2"; shift 2 ;;
    --hf-token) [[ -z "${2:-}" ]] && { echo "❌ --hf-token requiert TOKEN"; exit 1; }
                HF_TOKEN_ARG="$2"; shift 2 ;;
    --yes|-y)   NON_INTERACTIVE=true; shift ;;
    --models)   [[ -z "${2:-}" ]] && { echo "❌ --models requiert une liste"; exit 1; }
                PRESELECT="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Upload de NLLB-200-distilled-600M (CTranslate2 INT8) vers HuggingFace Dataset.

Usage: upload_models_to_hf.sh --repo OWNER/REPO [OPTIONS]

OPTIONS
  --repo OWNER/REPO   Dépôt HuggingFace Dataset cible
  --hf-token TOKEN    Token HuggingFace (accès Write)
  --yes, -y           Mode non-interactif : synchronise tout sans demander
  -h, --help          Cette aide

WORKFLOW
  1. Convertir  : ./scripts/prepare_translation_models.sh
  2. Uploader   : ./scripts/upload_models_to_hf.sh --repo Timteamteem/nllb-ct2
EOF
      exit 0 ;;
    *) echo "❌ Option inconnue : $1"; exit 1 ;;
  esac
done

[[ -z "$HF_REPO" ]] && { echo "❌ --repo OWNER/REPO requis."; exit 1; }

# Token : argument > .hf_token > $HF_TOKEN
if [[ -n "$HF_TOKEN_ARG" ]]; then
  export HF_TOKEN="$HF_TOKEN_ARG"
elif [[ -f "$HF_TOKEN_CACHE" ]]; then
  export HF_TOKEN="$(< "$HF_TOKEN_CACHE")"
  echo "ℹ  Token HF lu depuis .hf_token"
fi

if ! PYTHONPATH="$PKGS_DIR" python3 -c "import huggingface_hub" 2>/dev/null; then
  echo "❌ huggingface_hub non disponible dans .ct2_cache/pkgs."
  echo "   Exécutez d'abord : ./scripts/prepare_translation_models.sh --small"
  exit 1
fi

# ─── Script Python : comparaison + sélection + upload ────────────────────────
_PY_UPLOAD=$(mktemp /tmp/upload_hf_XXXXXXXX.py)
trap 'rm -f "$_PY_UPLOAD"' EXIT

cat > "$_PY_UPLOAD" <<'PYEOF'
import os, sys, hashlib
from pathlib import Path

repo_id    = os.environ["_HF_REPO"]
token      = os.environ.get("HF_TOKEN") or None
models_dir = Path(os.environ["_MODELS_DIR"])
non_interactive = os.environ.get("_NON_INTERACTIVE") == "true"
preselect_str   = os.environ.get("_PRESELECT", "")

G = '\033[0;32m'; Y = '\033[1;33m'; B = '\033[0;34m'
R = '\033[0;31m'; N = '\033[0m'

ALL_KEYS = [
    "nllb-200-distilled-600M",
]

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def fmt_size(n):
    return f"{n/1048576:.0f} Mo" if n > 0 else "—"

# ── 1. Lire le dépôt distant ──────────────────────────────────────────────────
from huggingface_hub import HfApi

api = HfApi(token=token)
remote_hashes = {}
repo_exists = True

print(f"\n{B}🔍 Lecture du dépôt {repo_id}…{N}")
try:
    for item in api.list_repo_tree(repo_id=repo_id, repo_type="dataset", recursive=True, token=token):
        if not hasattr(item, "size"):
            continue
        lfs = getattr(item, "lfs", None)
        remote_hashes[item.path] = getattr(lfs, "sha256", None) if lfs else None
    print(f"   {G}✓ {len(remote_hashes)} fichier(s){N}\n")
except Exception as e:
    if "404" in str(e) or "not found" in str(e).lower():
        print(f"   {Y}Dépôt introuvable — sera créé à l'upload.{N}\n")
        repo_exists = False
    else:
        print(f"   {Y}⚠ {e}{N}\n")

# ── 2. Comparer les SHA-256 locaux ────────────────────────────────────────────
OK = "ok"; NEW = "new"; OUTDATED = "outdated"; NO_LOCAL = "no_local"

results = []
print("   Calcul des SHA-256 locaux…")
for key in ALL_KEYS:
    local_bin = models_dir / key / "model.bin"
    if not local_bin.exists():
        results.append({"key": key, "status": NO_LOCAL, "size": 0})
        continue
    size = sum(f.stat().st_size for f in (models_dir / key).iterdir()
               if f.is_file() and not f.name.startswith("."))
    print(f"   {key}…", end="\r")
    sha = sha256_of(str(local_bin))
    remote_sha = remote_hashes.get(f"{key}/model.bin")
    if remote_sha is None and f"{key}/model.bin" not in remote_hashes:
        status = NEW
    elif remote_sha is None:
        status = OUTDATED
    elif remote_sha == sha:
        status = OK
    else:
        status = OUTDATED
    results.append({"key": key, "status": status, "size": size})

print(" " * 50, end="\r")

# ── 3. Tableau ────────────────────────────────────────────────────────────────
ICON  = {OK: f"{G}✅{N}", NEW: f"{B}🆕{N}", OUTDATED: f"{Y}🔄{N}", NO_LOCAL: "  "}
LABEL = {OK: f"{G}À jour{N}", NEW: f"{B}→ À uploader{N}",
         OUTDATED: f"{Y}→ À mettre à jour{N}", NO_LOCAL: "  (absent localement)"}

print(f"  {'Modèle':<22} {'Taille':>8}   Statut")
print(f"  {'─'*22} {'─'*8}   {'─'*24}")
uploadable = []
for r in results:
    print(f"  {ICON[r['status']]} {r['key']:<21} {fmt_size(r['size']):>8}   {LABEL[r['status']]}")
    if r["status"] in (NEW, OUTDATED):
        uploadable.append(r["key"])

n_ok = sum(1 for r in results if r["status"] == OK)
print(f"\n  {G}{n_ok} à jour{N}  ·  {B}{sum(1 for r in results if r['status']==NEW)} à uploader{N}"
      f"  ·  {Y}{sum(1 for r in results if r['status']==OUTDATED)} à mettre à jour{N}\n")

if not uploadable:
    print(f"{G}✅ Tout est synchronisé.{N}\n")
    sys.exit(0)

# ── 4. Sélection ──────────────────────────────────────────────────────────────
to_upload = []

if preselect_str:
    forced = [k.strip() for k in preselect_str.split(",") if k.strip()]
    to_upload = [k for k in forced if any(r["key"] == k and r["status"] != NO_LOCAL for r in results)]
    if not to_upload:
        print(f"{Y}Aucun modèle uploadable dans la sélection.{N}")
        sys.exit(0)
elif non_interactive:
    to_upload = uploadable
else:
    print(f"{B}   Actions :{N}")
    print(f"   {B}[Entrée]{N} Synchroniser tout  ({len(uploadable)} modèle(s))")
    print(f"   {B}[1]{N}      Choisir les modèles")
    print(f"   {B}[q]{N}      Quitter\n")
    try:
        choice = input("   > ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print("\nAnnulé."); sys.exit(0)

    if choice == "q":
        print("Annulé."); sys.exit(0)
    elif choice == "1":
        for i, k in enumerate(uploadable, 1):
            r = next(x for x in results if x["key"] == k)
            badge = "🆕" if r["status"] == NEW else "🔄"
            print(f"   {i:2})  {badge}  {k:<22} {fmt_size(r['size'])}")
        print()
        try:
            nums_str = input("   Numéros séparés par espaces : ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAnnulé."); sys.exit(0)
        for n in nums_str.split():
            try:
                idx = int(n) - 1
                if 0 <= idx < len(uploadable):
                    to_upload.append(uploadable[idx])
            except ValueError:
                pass
        if not to_upload:
            print(f"{Y}Aucune sélection valide.{N}"); sys.exit(0)
    else:
        to_upload = uploadable

# ── 5. Upload via upload_folder + hf_transfer ─────────────────────────────────
# hf_transfer (backend Rust) est activé via HF_HUB_ENABLE_HF_TRANSFER=1.
# upload_folder gère le LFS, le progress et le retry automatiquement.
if token:
    from huggingface_hub import login
    login(token=token, add_to_git_credential=False)

if not repo_exists:
    try:
        api.create_repo(repo_id=repo_id, repo_type="dataset", exist_ok=True, private=False)
        print(f"   {G}✓ Dépôt Dataset créé{N}")
    except Exception as e:
        print(f"   {Y}⚠ create_repo : {e}{N}")

print(f"\n{B}📤 Upload de {len(to_upload)} modèle(s)…{N}\n")
ok_uploads, fail_uploads = [], []

try:
    for key in to_upload:
        model_path = models_dir / key
        files = [f for f in model_path.iterdir() if f.is_file() and not f.name.startswith(".")]
        size_mb = sum(f.stat().st_size for f in files) / 1048576
        r = next(x for x in results if x["key"] == key)
        badge = "🆕" if r["status"] == NEW else "🔄"
        print(f"  {badge} {key}  ({size_mb:.0f} Mo, {len(files)} fichier(s))…")
        try:
            api.upload_folder(
                folder_path=str(model_path),
                path_in_repo=key,
                repo_id=repo_id,
                repo_type="dataset",
                ignore_patterns=[".*"],
                commit_message=f"Upload {key}",
            )
            print(f"     {G}✅ {key}{N}")
            ok_uploads.append(key)
        except KeyboardInterrupt:
            raise
        except Exception as e:
            print(f"     {R}❌ {key} : {e}{N}")
            fail_uploads.append(key)

except KeyboardInterrupt:
    print(f"\n{Y}⚠  Upload interrompu.{N}")
    sys.exit(130)

print()
summary = f"{G}✅ {len(ok_uploads)} modèle(s) uploadé(s){N}"
if fail_uploads:
    summary += f"  {R}· {len(fail_uploads)} échec(s) : {', '.join(fail_uploads)}{N}"
print(summary)
print(f"\n   Dépôt : https://huggingface.co/datasets/{repo_id}\n")

if fail_uploads:
    sys.exit(1)
PYEOF

export _HF_REPO="$HF_REPO"
export _MODELS_DIR="$MODELS_DIR"
export _NON_INTERACTIVE="$NON_INTERACTIVE"
export _PRESELECT="$PRESELECT"

HF_XET_HIGH_PERFORMANCE=1 PYTHONPATH="$PKGS_DIR" python3 "$_PY_UPLOAD"
