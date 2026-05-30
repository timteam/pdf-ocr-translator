#!/bin/bash
#
# Upload interactif des modèles CTranslate2 vers un dépôt HuggingFace Dataset.
# Compare les hashs locaux (SHA-256 de model.bin) avec ceux du dépôt pour
# n'uploader que ce qui est absent ou modifié.
#
# Usage :
#   ./scripts/upload_models_to_hf.sh --repo Timteamteem/opus-mt-ct2 --hf-token hf_...
#   ./scripts/upload_models_to_hf.sh --repo Timteamteem/opus-mt-ct2 --yes   # non-interactif
#   ./scripts/upload_models_to_hf.sh --repo Timteamteem/opus-mt-ct2 --models ja-en,en-ROMANCE
#
# Prérequis : avoir exécuté prepare_translation_models.sh au moins une fois
# (installe huggingface_hub dans .ct2_cache/pkgs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/../flutter_app/assets/translation_models"
PKGS_DIR="$SCRIPT_DIR/../.ct2_cache/pkgs"
HF_TOKEN_CACHE="$SCRIPT_DIR/../.hf_token"

export _HF_REPO=""
export _HF_TOKEN=""
export _NON_INTERACTIVE="false"
export _PRESELECT=""
export _MODELS_DIR="$MODELS_DIR"

# ─── Arguments ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     [[ -z "${2:-}" ]] && { echo "❌ --repo requiert OWNER/REPO"; exit 1; }
                export _HF_REPO="$2"; shift 2 ;;
    --hf-token) [[ -z "${2:-}" ]] && { echo "❌ --hf-token requiert TOKEN"; exit 1; }
                export _HF_TOKEN="$2"; shift 2 ;;
    --yes|-y)   export _NON_INTERACTIVE="true"; shift ;;
    --models)   [[ -z "${2:-}" ]] && { echo "❌ --models requiert une liste de clés"; exit 1; }
                export _PRESELECT="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Upload interactif des modèles CTranslate2 vers HuggingFace Dataset.
Compare les hashs (SHA-256 model.bin) pour n'uploader que le nécessaire.

Usage: upload_models_to_hf.sh --repo OWNER/REPO [OPTIONS]

OPTIONS
  --repo OWNER/REPO   Dépôt HuggingFace Dataset cible
  --hf-token TOKEN    Token HuggingFace avec accès Write
  --yes, -y           Mode non-interactif : synchronise tout sans demander
  --models KEY,...    Pré-sélectionner des modèles (ex: ja-en,en-ROMANCE)
  -h, --help          Cette aide

WORKFLOW
  1. Convertir les modèles  : ./scripts/prepare_translation_models.sh --small
  2. Uploader               : ./scripts/upload_models_to_hf.sh --repo Timteamteem/opus-mt-ct2
  3. Flutter constante      : flutter_app/lib/services/model_download_service.dart
                              → const String kModelHfRepo = 'Timteamteem/opus-mt-ct2';
EOF
      exit 0 ;;
    *) echo "❌ Option inconnue : $1"; exit 1 ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────
if [[ -z "$_HF_REPO" ]]; then
  echo "❌ --repo OWNER/REPO requis."
  echo "   Exemple : $0 --repo Timteamteem/opus-mt-ct2 --hf-token hf_..."
  exit 1
fi

# Token : argument > cache .hf_token > variable d'environnement HF_TOKEN
if [[ -z "$_HF_TOKEN" && -f "$HF_TOKEN_CACHE" ]]; then
  export _HF_TOKEN="$(< "$HF_TOKEN_CACHE")"
  echo "ℹ  Token HF lu depuis .hf_token"
elif [[ -z "$_HF_TOKEN" && -n "${HF_TOKEN:-}" ]]; then
  export _HF_TOKEN="$HF_TOKEN"
fi

# huggingface_hub disponible dans le cache de conversion ?
if ! PYTHONPATH="$PKGS_DIR" python3 -c "import huggingface_hub" 2>/dev/null; then
  echo "❌ huggingface_hub non disponible dans .ct2_cache/pkgs."
  echo "   Exécutez d'abord : ./scripts/prepare_translation_models.sh --small"
  exit 1
fi

# ─── Script Python principal ──────────────────────────────────────────────────
PYTHONPATH="$PKGS_DIR" python3 <<'PYEOF'
import os, sys, hashlib
from pathlib import Path

# ── Env ───────────────────────────────────────────────────────────────────────
repo_id         = os.environ['_HF_REPO']
token           = os.environ.get('_HF_TOKEN') or None
models_dir      = Path(os.environ['_MODELS_DIR'])
non_interactive = os.environ.get('_NON_INTERACTIVE', 'false') == 'true'
preselect_str   = os.environ.get('_PRESELECT', '')

# ── Couleurs ANSI ─────────────────────────────────────────────────────────────
G = '\033[0;32m'; Y = '\033[1;33m'; B = '\033[0;34m'
R = '\033[0;31m'; C = '\033[0;36m'; N = '\033[0m'

# ── Liste canonique des 24 modèles ────────────────────────────────────────────
ALL_KEYS = [
    "ja-en", "zh-en", "ko-en", "ru-en", "ar-en", "hi-en", "th-en", "vi-en",
    "de-en", "nl-en", "pl-en", "ROMANCE-en",
    "en-ROMANCE", "en-de", "en-nl", "en-ru", "en-hi", "en-zh", "en-ar",
    "en-vi", "en-mul", "en-sla", "tc-big-en-ar", "tc-big-en-ko",
]

# ── Utilitaires ───────────────────────────────────────────────────────────────
def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

def fmt_size(n):
    return f"{n/1048576:.0f} Mo" if n > 0 else '—'

# ── 1. Récupération du dépôt HF (un seul appel API) ──────────────────────────
from huggingface_hub import HfApi

api = HfApi(token=token)
remote_hashes = {}   # "key/model.bin" -> sha256 str (ou None si pas en LFS)
repo_exists   = True

print(f"\n{B}🔍 Lecture du dépôt {repo_id}…{N}")
try:
    for item in api.list_repo_tree(
        repo_id=repo_id, repo_type="dataset",
        recursive=True, token=token,
    ):
        if not hasattr(item, 'path') or not hasattr(item, 'size'):
            continue  # c'est un dossier
        lfs = getattr(item, 'lfs', None)
        sha = getattr(lfs, 'sha256', None) if lfs else None
        remote_hashes[item.path] = sha
    print(f"   {G}✓ {len(remote_hashes)} fichier(s) indexé(s){N}\n")
except Exception as e:
    err = str(e)
    if '404' in err or 'not found' in err.lower():
        print(f"   {Y}Dépôt introuvable — sera créé à l'upload.{N}\n")
        repo_exists = False
    else:
        print(f"   {Y}⚠ Impossible de lire le dépôt ({e}){N}\n")

# ── 2. Analyse des modèles locaux ─────────────────────────────────────────────
OK       = 'ok'       # hash identique
NEW      = 'new'      # absent du dépôt
OUTDATED = 'outdated' # hash différent
NO_LOCAL = 'no_local' # pas de model.bin local

results = []
print(f"   Calcul des SHA-256 locaux…")
for key in ALL_KEYS:
    local_bin = models_dir / key / 'model.bin'
    remote_key = f"{key}/model.bin"

    if not local_bin.exists():
        results.append({'key': key, 'status': NO_LOCAL, 'size': 0})
        continue

    size = sum(
        f.stat().st_size for f in (models_dir / key).iterdir()
        if f.is_file() and not f.name.startswith('.')
    )
    print(f"   {key}…", end='\r')
    local_sha = sha256_of(str(local_bin))

    if remote_key not in remote_hashes:
        status = NEW
    elif remote_hashes[remote_key] is None:
        # Fichier sur HF mais pas en LFS (trop petit pour LFS ?) → on compare via re-upload
        status = OUTDATED
    elif remote_hashes[remote_key] == local_sha:
        status = OK
    else:
        status = OUTDATED

    results.append({'key': key, 'status': status, 'size': size})

print(' ' * 50, end='\r')

# ── 3. Tableau récapitulatif ──────────────────────────────────────────────────
ICON  = {OK: f'{G}✅{N}', NEW: f'{B}🆕{N}', OUTDATED: f'{Y}🔄{N}', NO_LOCAL: '  '}
LABEL = {
    OK:       f'{G}À jour{N}',
    NEW:      f'{B}→ À uploader{N}',
    OUTDATED: f'{Y}→ À mettre à jour{N}',
    NO_LOCAL: '  (pas de modèle local)',
}

print(f"  {'Modèle':<23} {'Taille':>8}   Statut")
print(f"  {'─'*23} {'─'*8}   {'─'*26}")

uploadable = []
for r in results:
    print(f"  {ICON[r['status']]} {r['key']:<22} {fmt_size(r['size']):>8}   {LABEL[r['status']]}")
    if r['status'] in (NEW, OUTDATED):
        uploadable.append(r['key'])

n_ok  = sum(1 for r in results if r['status'] == OK)
n_new = sum(1 for r in results if r['status'] == NEW)
n_upd = sum(1 for r in results if r['status'] == OUTDATED)
n_nil = sum(1 for r in results if r['status'] == NO_LOCAL)

print(f"\n  {G}{n_ok} à jour{N}  ·  {B}{n_new} à uploader{N}  ·  {Y}{n_upd} à mettre à jour{N}  ·  {n_nil} absents localement\n")

if not uploadable:
    print(f"{G}✅ Tout est synchronisé — aucun upload nécessaire.{N}\n")
    sys.exit(0)

# ── 4. Sélection ──────────────────────────────────────────────────────────────
to_upload = []

if preselect_str:
    # --models : forcer la sélection (même si à jour — l'utilisateur l'a demandé)
    forced = [k.strip() for k in preselect_str.split(',') if k.strip()]
    to_upload = [k for k in forced if any(r['key'] == k and r['status'] != NO_LOCAL for r in results)]
    if not to_upload:
        print(f"{Y}Aucun modèle uploadable parmi la sélection fournie.{N}")
        sys.exit(0)

elif non_interactive:
    to_upload = uploadable

else:
    print(f"{B}   Actions :{N}")
    print(f"   {B}[Entrée]{N} Synchroniser tout  ({len(uploadable)} modèle(s) : {', '.join(uploadable)})")
    print(f"   {B}[1]{N}      Choisir les modèles à uploader/mettre à jour")
    print(f"   {B}[q]{N}      Quitter sans uploader")
    print()

    try:
        choice = input("   > ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print("\nAnnulé.")
        sys.exit(0)

    if choice == 'q':
        print("Annulé.")
        sys.exit(0)

    elif choice == '1':
        print(f"\n   Modèles uploadables ({len(uploadable)}) :")
        for i, k in enumerate(uploadable, 1):
            r = next(x for x in results if x['key'] == k)
            badge = '🆕' if r['status'] == NEW else '🔄'
            print(f"   {i:2})  {badge}  {k:<22} {fmt_size(r['size'])}")
        print()
        try:
            nums_str = input("   Numéros séparés par espaces : ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAnnulé.")
            sys.exit(0)
        for n in nums_str.split():
            try:
                idx = int(n) - 1
                if 0 <= idx < len(uploadable):
                    to_upload.append(uploadable[idx])
            except ValueError:
                pass
        if not to_upload:
            print(f"{Y}Aucune sélection valide — abandon.{N}")
            sys.exit(0)

    else:  # Entrée ou autre → synchroniser tout
        to_upload = uploadable

# ── 5. Upload ─────────────────────────────────────────────────────────────────
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

for key in to_upload:
    model_path = models_dir / key
    files = [f for f in model_path.iterdir() if f.is_file() and not f.name.startswith('.')]
    size_mb = sum(f.stat().st_size for f in files) / 1048576
    r = next(x for x in results if x['key'] == key)
    badge = '🆕' if r['status'] == NEW else '🔄'
    print(f"  {badge} {key}  ({size_mb:.0f} Mo, {len(files)} fichier(s))…")
    try:
        api.upload_folder(
            folder_path=str(model_path),
            path_in_repo=key,
            repo_id=repo_id,
            repo_type="dataset",
            ignore_patterns=[".*"],
        )
        print(f"     {G}✅ {key}{N}")
        ok_uploads.append(key)
    except Exception as e:
        print(f"     {R}❌ {key} : {e}{N}")
        fail_uploads.append(key)

print()
summary = f"{G}✅ {len(ok_uploads)} modèle(s) uploadé(s){N}"
if fail_uploads:
    summary += f"  {R}· {len(fail_uploads)} échec(s) : {', '.join(fail_uploads)}{N}"
print(summary)
print(f"\n   Dépôt : https://huggingface.co/datasets/{repo_id}\n")

if fail_uploads:
    sys.exit(1)
PYEOF
