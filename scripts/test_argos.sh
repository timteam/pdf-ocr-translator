#!/bin/bash
# Test Opus-MT (Argos Translate) sur les 183 segments OCR du log Notice Iseki TK29.
# Télécharge directement les .argosmodel (zip CTranslate2), les dézippe,
# et traduit via le ctranslate2 déjà dans le snap — aucune dépendance Python en plus.
#
# Usage : bash scripts/test_argos.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Desktop/Notice Iseki TK 29 1p complexe_fr/Notice Iseki TK 29 1p complexe_fr.log"
MODELS_DIR="$SCRIPT_DIR/../.argos_models"
INPUT="/tmp/argos_test_input.json"
OUTPUT="/tmp/argos_test_output.json"

# Python + libs CTranslate2 depuis le snap (déjà disponibles)
PYTHON="/snap/gnome-46-2404/153/usr/bin/python3.12"
PYENV="/snap/pdf-ocr-translator/x3/pyenv"

# ── Vérification du log ──────────────────────────────────────────────────────
if [[ ! -f "$LOG" ]]; then
  echo "❌ Log introuvable : $LOG"
  exit 1
fi

# ── Extraction des blocs OCR ─────────────────────────────────────────────────
python3 -c "
import re, json, sys
log = open('$LOG').read()
blocs = re.findall(r'bloc\[(\d+)\] — \"(.+?)\" \| bb:', log)
texts = [t for _, t in blocs]
if not texts: sys.exit('Aucun bloc OCR trouvé')
json.dump(texts, open('$INPUT', 'w'), ensure_ascii=False)
print(f'{len(texts)} blocs OCR extraits → $INPUT')
"

# ── Téléchargement des modèles Argos ─────────────────────────────────────────
mkdir -p "$MODELS_DIR"

download_model() {
  local from="$1" to="$2"
  local dir="$MODELS_DIR/${from}_${to}"
  if [[ -d "$dir/model" ]]; then
    echo "  ${from}→${to} : déjà présent"
    return
  fi
  echo "  Récupération de l'URL ${from}→${to} depuis l'index Argos…"
  local url
  url=$(curl -sf "https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json" | python3 -c "
import sys, json
try:
    pkgs = json.load(sys.stdin)
    p = next((x for x in pkgs if x['from_code']=='$from' and x['to_code']=='$to'), None)
    print(p['links'][0] if p else '', end='')
except: pass
")
  if [[ -z "$url" ]]; then
    echo "  ❌ Package ${from}→${to} introuvable dans l'index"
    exit 1
  fi
  local zip="/tmp/argos_${from}_${to}.argosmodel"
  echo "  Téléchargement ${from}→${to} : $url"
  curl -L --progress-bar "$url" -o "$zip"
  mkdir -p "$dir"
  unzip -q "$zip" -d "$dir"
  # Le zip contient un sous-répertoire — on l'aplatit si nécessaire
  local inner
  inner=$(ls "$dir")
  if [[ -d "$dir/$inner" && "$inner" != "model" ]]; then
    mv "$dir/$inner/"* "$dir/"
    rmdir "$dir/$inner"
  fi
  rm -f "$zip"
  echo "  ${from}→${to} : installé ✓"
}

echo "Vérification des modèles Opus-MT…"
download_model ja en
download_model en fr

# ── Traduction directe via CTranslate2 (snap) ────────────────────────────────
echo ""
echo "Traduction ja→en→fr avec Opus-MT (CTranslate2 du snap)…"

PYTHONPATH="$PYENV" "$PYTHON" - \
    "$MODELS_DIR/ja_en" \
    "$MODELS_DIR/en_fr" \
    "$INPUT" \
    "$OUTPUT" \
    "${OUTPUT/output/nllb}" \
    <<'PYEOF'
import sys, json, time
import sentencepiece as spm
import ctranslate2

dir_ja_en, dir_en_fr, path_in, path_out, path_nllb = sys.argv[1:6]

def load_model(model_dir):
    # Les modèles Argos utilisent un sentencepiece.model partagé (source + cible)
    # et le modèle CT2 dans le sous-dossier model/
    translator = ctranslate2.Translator(
        model_dir + "/model", device="cpu", inter_threads=1, intra_threads=2
    )
    sp = spm.SentencePieceProcessor()
    sp.load(model_dir + "/sentencepiece.model")
    return translator, sp

def translate_batch(texts, translator, sp, batch_size=32):
    results = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        encoded = [sp.encode(t, out_type=str) for t in batch]
        out = translator.translate_batch(encoded, beam_size=2, max_decoding_length=256)
        for r in out:
            results.append(sp.decode(r.hypotheses[0]))
    return results

print("Chargement ja→en…", flush=True)
t_ja_en, sp_ja_en = load_model(dir_ja_en)
print("Chargement en→fr…", flush=True)
t_en_fr, sp_en_fr = load_model(dir_en_fr)

texts = json.load(open(path_in))
non_empty = [(i, t) for i, t in enumerate(texts) if t.strip()]
src_texts = [t for _, t in non_empty]

t0 = time.monotonic()
print(f"\n{len(non_empty)} segments non-vides sur {len(texts)} → ja→en…", flush=True)
en_texts = translate_batch(src_texts, t_ja_en, sp_ja_en)

print(f"→ en→fr…", flush=True)
fr_texts = translate_batch(en_texts, t_en_fr, sp_en_fr)
dt = time.monotonic() - t0

results = [""] * len(texts)
for (i, _), fr in zip(non_empty, fr_texts):
    results[i] = fr

json.dump(results, open(path_out, "w"), ensure_ascii=False)

# ── Statistiques ──────────────────────────────────────────────────────────────
bad_markers = ["kor_Hang","yue_Hant","jpn_Jpan"]
bad   = sum(1 for t in results if any(m in t for m in bad_markers) or t.count("--") > 3)
empty = sum(1 for t in results if not t.strip())
good  = len(results) - bad - empty

print(f"\n{'='*80}")
print(f"Terminé — {dt:.1f}s ({dt/len(non_empty):.2f}s/seg)")
print(f"  Correct/lisible : {good}/{len(results)} ({good*100//len(results)}%)")
print(f"  Corrompu        : {bad}/{len(results)} ({bad*100//len(results)}%)")
print(f"  Vide            : {empty}/{len(results)} ({empty*100//len(results)}%)")
print(f"{'='*80}\n")

# ── Comparatif côte à côte ────────────────────────────────────────────────────
nllb_results = None
try:
    nllb_results = json.load(open("/tmp/test_nllb_output.json"))
except FileNotFoundError:
    pass

src_all = json.load(open(path_in))
print(f"{'#':>3}  {'JAPONAIS (OCR)':<38}  {'OPUS-MT (Argos)':<40}" +
      ("  NLLB" if nllb_results else ""))
print("-" * (90 if not nllb_results else 130))
for i, (src, argos) in enumerate(zip(src_all, results)):
    nllb_col = f"  {nllb_results[i][:39]}" if nllb_results else ""
    print(f"{i:>3}  {src[:37]:<38}  {argos[:39]:<40}{nllb_col}")
PYEOF
