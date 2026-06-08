#!/usr/bin/env python3
"""
CLI pipeline pour pdf-ocr-translator — OCR + traduction sans IHM Flutter.

Conçu pour la boucle d'amélioration itérative :
  1. Lancer ce script sur des PDFs de test
  2. Lire les rapports par page dans <output>/
  3. Identifier les défauts OCR / traduction
  4. Modifier paddle_runner.py ou opusmt_translate.py dans les sources
  5. Relancer (pas de rebuild snap — les scripts source sont utilisés directement)
  6. Comparer avant/après

Usage :
  python3 scripts/cli_pipeline.py [options] <input>

Arguments :
  <input>    Fichier PDF ou répertoire contenant des PDFs

Options :
  --src LANG   Langue source BCP-47 (défaut: auto — détection FastText par page)
               Exemples : ja  en  de  fr  zh  ko  ru  ar
  --tgt LANG   Langue cible (défaut: fr)
  --out DIR    Répertoire de sortie (défaut: ./cli_output)
  --dpi N      DPI de rendu (défaut: 600)
  --pages A-B  Traiter seulement les pages A à B (1-indexé, ex: --pages 1-3)
  --snap PATH  Chemin du snap (détecté automatiquement)
  --no-cache   Désactiver le cache de traduction (re-traduit même les textes déjà vus)

Sorties par PDF :
  <out>/<pdf_stem>/page_N_ocr.json        Blocs OCR bruts
  <out>/<pdf_stem>/page_N_translated.json Blocs traduits + méta
  <out>/<pdf_stem>/page_N_report.txt      Comparaison côte à côte lisible
  <out>/<pdf_stem>/page_N_paddle.log      Stderr paddle_runner.py (diagnostic OCR)
  <out>/<pdf_stem>/page_N_translate.log   Stderr opusmt_translate.py (diagnostic trad.)
  <out>/<pdf_stem>/summary.txt            Statistiques globales du document
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ─── Auto-détection de l'environnement ────────────────────────────────────────

REPO_ROOT    = Path(__file__).resolve().parent.parent
SCRIPTS_SRC  = REPO_ROOT / "flutter_app" / "assets" / "scripts"
MODELS_SRC   = REPO_ROOT / "flutter_app" / "assets" / "models"

SNAP_ROOT    = Path("/snap/pdf-ocr-translator/current")
GNOME_SNAP   = Path("/snap/gnome-46-2404/current")

PYTHON312    = GNOME_SNAP / "usr" / "bin" / "python3.12"
PYENV        = SNAP_ROOT  / "pyenv"
TRANS_MODELS = SNAP_ROOT  / "data" / "flutter_assets" / "assets" / "translation_models"

LIB_DIRS = [
    "numpy.libs", "opencv_python.libs", "ctranslate2.libs",
    "pillow.libs", "shapely.libs",
]


def find_python312(snap_override: str | None = None) -> Path:
    """Résout le binaire python3.12 utilisable depuis ce script."""
    if snap_override:
        snap = Path(snap_override)
        gnome = snap.parent.parent / "gnome-46-2404" / "current"
        candidate = gnome / "usr" / "bin" / "python3.12"
        if candidate.exists():
            return candidate

    if PYTHON312.exists():
        return PYTHON312

    # Fallback : python3.12 système
    found = shutil.which("python3.12")
    if found:
        return Path(found)

    sys.exit(
        "ERREUR : python3.12 introuvable.\n"
        "Assurez-vous que le snap pdf-ocr-translator est installé\n"
        "ou que python3.12 est disponible dans le PATH système."
    )


def build_python_env(snap_root: Path | None = None) -> dict:
    """Construit le dict d'environnement pour les sous-processus Python 3.12."""
    env = dict(os.environ)
    root = snap_root or SNAP_ROOT
    pyenv = root / "pyenv"
    if not pyenv.exists():
        return env

    env["PYTHONPATH"] = str(pyenv)

    lib_paths = [str(pyenv / d) for d in LIB_DIRS if (pyenv / d).exists()]
    if lib_paths:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = ":".join(lib_paths + ([existing] if existing else []))

    # paddle_runner.py lit $SNAP pour localiser les modèles ONNX.
    # On force la valeur correcte quel que soit l'environnement shell courant
    # (ex: $SNAP==/snap/code/xxx quand on lance depuis VS Code).
    env["SNAP"] = str(root)

    return env


def get_translation_models_dir(snap_root: Path | None = None) -> Path:
    return (snap_root or SNAP_ROOT) / "data" / "flutter_assets" / "assets" / "translation_models"


def required_model_dirs(src: str, tgt: str) -> list[str]:
    """Retourne les répertoires de modèles requis pour src→tgt (pivot via en)."""
    if src == tgt:
        return []
    if src == "en":
        return [f"en-{tgt}"]
    if tgt == "en":
        return [f"{src}-en"]
    return [f"{src}-en", f"en-{tgt}"]


# ─── Rendu PDF ────────────────────────────────────────────────────────────────

def get_page_count(pdf_path: Path) -> int:
    result = subprocess.run(
        ["pdfinfo", str(pdf_path)], capture_output=True, text=True, check=True
    )
    import re
    m = re.search(r"Pages:\s+(\d+)", result.stdout)
    return int(m.group(1)) if m else 1


def render_page(pdf_path: Path, page: int, dpi: int, out_dir: Path) -> Path:
    """Rend une page en PNG et retourne le chemin du fichier produit."""
    prefix = out_dir / f"page_{page}"
    subprocess.run(
        [
            "pdftoppm",
            "-r", str(dpi),
            "-png",
            "-f", str(page),
            "-l", str(page),
            str(pdf_path),
            str(prefix),
        ],
        check=True,
        capture_output=True,
    )
    # pdftoppm génère <prefix>-<N>.png ou <prefix>.png selon la version
    candidates = sorted(out_dir.glob(f"page_{page}*.png"))
    if not candidates:
        raise FileNotFoundError(f"pdftoppm n'a produit aucun PNG pour la page {page}")
    return candidates[-1]


# ─── OCR ──────────────────────────────────────────────────────────────────────

def ocr_page(image_path: Path, lang: str, python_bin: Path, env: dict) -> tuple[list[dict], str]:
    """
    Appelle paddle_runner.py ocr <image> <lang>.
    Retourne (blocs_json, stderr_log).
    """
    script = SCRIPTS_SRC / "paddle_runner.py"
    result = subprocess.run(
        [str(python_bin), str(script), "ocr", str(image_path), lang],
        env=env,
        capture_output=True,
        text=True,
    )
    stderr = result.stderr
    if result.returncode != 0:
        raise RuntimeError(f"paddle_runner.py a échoué (exit {result.returncode}):\n{stderr}")
    blocks = json.loads(result.stdout)
    return blocks, stderr


def detect_language(image_path: Path, python_bin: Path, env: dict) -> str:
    """
    Détecte la langue d'une image via paddle_runner.py detect + FastText.
    Retourne le code BCP-47 (ex: 'ja', 'fr', 'en').
    """
    script = SCRIPTS_SRC / "paddle_runner.py"
    result = subprocess.run(
        [str(python_bin), str(script), "detect", str(image_path)],
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  [WARN] Détection langue échouée, fallback 'en'", file=sys.stderr)
        return "en"

    data = json.loads(result.stdout)
    script_name = data.get("script", "latin")
    text = data.get("text", "")

    SCRIPT_MAP = {
        "japanese":   "ja",
        "cjk":        "zh",
        "korean":     "ko",
        "arabic":     "ar",
        "cyrillic":   "ru",
        "devanagari": "hi",
        "thai":       "th",
    }
    if script_name in SCRIPT_MAP:
        return SCRIPT_MAP[script_name]

    # Script latin → FastText
    if len(text.strip()) < 20:
        return "en"

    ft_script = SCRIPTS_SRC / "fasttext_detect.py"
    ft_model  = MODELS_SRC / "lid.176.ftz"
    ft_result = subprocess.run(
        [str(python_bin), str(ft_script), str(ft_model)],
        input=text[:1000],
        capture_output=True,
        text=True,
        env=env,
    )
    label = ft_result.stdout.strip().split("\n")[0].strip()
    if label.startswith("__label__"):
        code = label[len("__label__"):]
        supported = {"en","fr","de","es","it","pt","nl","pl","vi","ja","zh","ko","ru","ar","hi","th"}
        if code in supported:
            return code
    return "en"


# ─── Traduction ───────────────────────────────────────────────────────────────

def translate_blocks(
    texts: list[str],
    src: str,
    tgt: str,
    python_bin: Path,
    env: dict,
    models_dir: Path,
    cache: dict | None = None,
) -> tuple[list[str], str]:
    """
    Traduit une liste de textes via opusmt_translate.py.
    Retourne (traductions, stderr_log).
    cache: dict {src_text: translated} pour éviter de re-traduire.
    """
    if not texts:
        return [], ""
    if src == tgt:
        return list(texts), ""

    model_dirs = required_model_dirs(src, tgt)
    if not model_dirs:
        return list(texts), ""

    # Vérification modèles
    for d in model_dirs:
        model_bin = models_dir / d / "model" / "model.bin"
        if not model_bin.exists():
            raise FileNotFoundError(
                f"Modèle manquant : {model_bin}\n"
                f"Modèles disponibles : {sorted(p.name for p in models_dir.iterdir() if p.is_dir())}"
            )

    model_paths = [str(models_dir / d) for d in model_dirs]
    script = SCRIPTS_SRC / "opusmt_translate.py"

    # Cache côté CLI (évite de traduire deux fois le même segment)
    to_translate_indices = []
    results = list(texts)
    if cache is not None:
        for i, t in enumerate(texts):
            if t in cache:
                results[i] = cache[t]
            else:
                to_translate_indices.append(i)
    else:
        to_translate_indices = list(range(len(texts)))

    if not to_translate_indices:
        return results, ""

    batch = [texts[i] for i in to_translate_indices]
    result = subprocess.run(
        [str(python_bin), str(script)] + model_paths,
        input=json.dumps(batch),
        capture_output=True,
        text=True,
        env=env,
    )
    stderr = result.stderr
    if result.returncode != 0:
        raise RuntimeError(f"opusmt_translate.py a échoué (exit {result.returncode}):\n{stderr}")

    translated_batch = json.loads(result.stdout)
    for idx, translated in zip(to_translate_indices, translated_batch):
        results[idx] = translated
        if cache is not None:
            cache[texts[idx]] = translated

    return results, stderr


# ─── Rapport par page ─────────────────────────────────────────────────────────

def _box_iou(a: dict, b: dict) -> float:
    """IoU entre deux bounding boxes de blocs OCR."""
    ix1 = max(a.get("left", 0),   b.get("left", 0))
    iy1 = max(a.get("top", 0),    b.get("top", 0))
    ix2 = min(a.get("right", 0),  b.get("right", 0))
    iy2 = min(a.get("bottom", 0), b.get("bottom", 0))
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    inter = (ix2 - ix1) * (iy2 - iy1)
    area_a = (a.get("right",0) - a.get("left",0)) * (a.get("bottom",0) - a.get("top",0))
    area_b = (b.get("right",0) - b.get("left",0)) * (b.get("bottom",0) - b.get("top",0))
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def analyse_layout(blocks: list[dict], page: int) -> dict:
    """Analyse le placement des blocs : chevauchements, densité, distribution."""
    n = len(blocks)
    overlaps = []
    for i in range(n):
        for j in range(i + 1, n):
            iou = _box_iou(blocks[i], blocks[j])
            if iou > 0.05:
                overlaps.append({
                    "i": i, "j": j, "iou": round(iou, 3),
                    "text_i": blocks[i].get("text", "")[:30],
                    "text_j": blocks[j].get("text", "")[:30],
                })
    overlaps.sort(key=lambda o: -o["iou"])
    severe  = [o for o in overlaps if o["iou"] > 0.30]
    moderate = [o for o in overlaps if 0.10 < o["iou"] <= 0.30]
    return {
        "page": page,
        "n_blocks": n,
        "overlaps_severe":   len(severe),
        "overlaps_moderate": len(moderate),
        "worst_iou": overlaps[0]["iou"] if overlaps else 0.0,
        "details": overlaps[:10],  # top 10
    }


def write_page_report(
    page: int,
    lang_src: str,
    lang_tgt: str,
    ocr_blocks: list[dict],
    translations: list[str],
    out_dir: Path,
    timings: dict,
) -> dict:
    """Écrit un rapport lisible côte à côte + analyse de placement.

    Retourne le dict d'analyse de layout.
    """
    layout = analyse_layout(ocr_blocks, page)

    lines = [
        f"=== Page {page} | {lang_src} → {lang_tgt} ===",
        f"OCR : {len(ocr_blocks)} blocs  |  "
        f"Rendu: {timings.get('render', 0):.1f}s  "
        f"OCR: {timings.get('ocr', 0):.1f}s  "
        f"Trad: {timings.get('translate', 0):.1f}s",
        f"Layout : chevauchements sévères={layout['overlaps_severe']}  "
        f"modérés={layout['overlaps_moderate']}  "
        f"pire IoU={layout['worst_iou']:.2f}",
        "",
    ]

    if layout["overlaps_severe"]:
        lines.append("⚠ CHEVAUCHEMENTS SÉVÈRES (IoU>0.30) :")
        for o in layout["details"]:
            if o["iou"] > 0.30:
                lines.append(f"  Blocs {o['i']+1}↔{o['j']+1}  IoU={o['iou']:.2f}"
                             f"  «{o['text_i']}» ↔ «{o['text_j']}»")
        lines.append("")

    for i, (blk, trad) in enumerate(zip(ocr_blocks, translations)):
        left   = blk.get("left",   0)
        top    = blk.get("top",    0)
        right  = blk.get("right",  0)
        bottom = blk.get("bottom", 0)
        bb = f"  [{left:.0f},{top:.0f} {right-left:.0f}×{bottom-top:.0f}px]"
        orig = blk.get("text", "")
        conf = blk.get("confidence", 0.0)
        lines += [
            f"─── Bloc {i+1:02d} (conf={conf:.2f}){bb}",
            f"  SRC : {orig}",
            f"  TGT : {trad}",
            "",
        ]
    (out_dir / f"page_{page}_report.txt").write_text(
        "\n".join(lines), encoding="utf-8"
    )
    return layout


# ─── Pipeline par PDF ─────────────────────────────────────────────────────────

def process_pdf(
    pdf_path: Path,
    src_lang: str,
    tgt_lang: str,
    out_root: Path,
    dpi: int,
    page_range: tuple[int, int] | None,
    python_bin: Path,
    env: dict,
    models_dir: Path,
    use_cache: bool,
) -> dict:
    """Traite un PDF complet. Retourne un dict de stats."""
    stem = pdf_path.stem
    out_dir = out_root / stem
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"PDF : {pdf_path.name}")
    print(f"{'='*60}")

    page_count = get_page_count(pdf_path)
    p_start = page_range[0] if page_range else 1
    p_end   = min(page_range[1], page_count) if page_range else page_count

    print(f"Pages : {p_start}–{p_end} / {page_count} | DPI={dpi} | {src_lang}→{tgt_lang}")

    stats = {
        "pdf": str(pdf_path),
        "pages_processed": 0,
        "total_blocks": 0,
        "empty_translations": 0,
        "total_overlaps_severe": 0,
        "total_overlaps_moderate": 0,
        "errors": [],
        "timing_total": 0.0,
    }
    translation_cache: dict | None = {} if use_cache else None
    t0_total = time.time()

    for page in range(p_start, p_end + 1):
        print(f"\n  Page {page}/{p_end}")
        page_stats: dict = {}

        with tempfile.TemporaryDirectory(prefix="cli_pdf_") as tmp:
            tmp_path = Path(tmp)
            timings: dict = {}

            # ── Rendu ──────────────────────────────────────────────────────
            print(f"    Rendu {dpi} DPI…", end=" ", flush=True)
            t = time.time()
            try:
                img_path = render_page(pdf_path, page, dpi, tmp_path)
            except Exception as exc:
                print(f"ERREUR: {exc}")
                stats["errors"].append(f"p{page} rendu: {exc}")
                continue
            timings["render"] = time.time() - t
            print(f"{timings['render']:.1f}s")

            # ── Détection langue (si auto) ─────────────────────────────────
            effective_src = src_lang
            if src_lang == "auto":
                print(f"    Détection langue…", end=" ", flush=True)
                effective_src = detect_language(img_path, python_bin, env)
                print(effective_src)

            # ── OCR ────────────────────────────────────────────────────────
            print(f"    OCR ({effective_src})…", end=" ", flush=True)
            t = time.time()
            try:
                ocr_blocks, paddle_log = ocr_page(img_path, effective_src, python_bin, env)
            except Exception as exc:
                print(f"ERREUR: {exc}")
                stats["errors"].append(f"p{page} ocr: {exc}")
                continue
            timings["ocr"] = time.time() - t
            print(f"{timings['ocr']:.1f}s → {len(ocr_blocks)} blocs")

            # Sauvegarde logs OCR
            (out_dir / f"page_{page}_paddle.log").write_text(paddle_log, encoding="utf-8")
            (out_dir / f"page_{page}_ocr.json").write_text(
                json.dumps(ocr_blocks, ensure_ascii=False, indent=2), encoding="utf-8"
            )

            # ── Traduction ─────────────────────────────────────────────────
            texts = [b["text"] for b in ocr_blocks]
            translations = list(texts)  # défaut = texte original

            if texts and effective_src != tgt_lang:
                print(f"    Traduction {effective_src}→{tgt_lang} ({len(texts)} seg)…",
                      end=" ", flush=True)
                t = time.time()
                try:
                    translations, translate_log = translate_blocks(
                        texts, effective_src, tgt_lang, python_bin, env, models_dir,
                        cache=translation_cache,
                    )
                except Exception as exc:
                    print(f"ERREUR: {exc}")
                    stats["errors"].append(f"p{page} trad: {exc}")
                    translate_log = str(exc)
                else:
                    timings["translate"] = time.time() - t
                    print(f"{timings['translate']:.1f}s")

                (out_dir / f"page_{page}_translate.log").write_text(
                    translate_log, encoding="utf-8"
                )

            # ── Sauvegarde résultats ───────────────────────────────────────
            result_blocks = []
            empty = 0
            for blk, trad in zip(ocr_blocks, translations):
                if not trad.strip():
                    empty += 1
                result_blocks.append({**blk, "translation": trad})

            (out_dir / f"page_{page}_translated.json").write_text(
                json.dumps(result_blocks, ensure_ascii=False, indent=2), encoding="utf-8"
            )

            layout = write_page_report(
                page, effective_src, tgt_lang,
                ocr_blocks, translations, out_dir, timings,
            )

            stats["pages_processed"]      += 1
            stats["total_blocks"]          += len(ocr_blocks)
            stats["empty_translations"]    += empty
            stats["total_overlaps_severe"] += layout["overlaps_severe"]
            stats["total_overlaps_moderate"] += layout["overlaps_moderate"]

            duration = sum(timings.values())
            overlap_warn = (f" | ⚠ {layout['overlaps_severe']} chevauch. sévères"
                           if layout["overlaps_severe"] else "")
            print(f"    → {len(ocr_blocks)} blocs | {empty} trad. vides | {duration:.1f}s{overlap_warn}")

    stats["timing_total"] = time.time() - t0_total

    # ── Résumé du document ─────────────────────────────────────────────────────
    summary_lines = [
        f"PDF : {pdf_path}",
        f"Pages traitées    : {stats['pages_processed']} / {p_end - p_start + 1}",
        f"Blocs totaux      : {stats['total_blocks']}",
        f"Trad. vides       : {stats['empty_translations']}",
        f"Chevauch. sévères : {stats['total_overlaps_severe']}",
        f"Chevauch. modérés : {stats['total_overlaps_moderate']}",
        f"Durée totale      : {stats['timing_total']:.1f}s",
    ]
    if stats["errors"]:
        summary_lines += ["", "ERREURS :"] + [f"  - {e}" for e in stats["errors"]]

    summary_text = "\n".join(summary_lines)
    (out_dir / "summary.txt").write_text(summary_text, encoding="utf-8")

    print(f"\n  Terminé : {stats['pages_processed']} pages | "
          f"{stats['total_blocks']} blocs | {stats['timing_total']:.1f}s")
    print(f"  Rapports : {out_dir}/")

    return stats


# ─── Point d'entrée ───────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="CLI pipeline OCR+traduction pour pdf-ocr-translator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input", help="Fichier PDF ou répertoire")
    parser.add_argument("--src",    default="auto",
                        help="Langue source BCP-47 ou 'auto' (défaut: auto)")
    parser.add_argument("--tgt",    default="fr",  help="Langue cible (défaut: fr)")
    parser.add_argument("--out",    default="./cli_output", help="Répertoire de sortie")
    parser.add_argument("--dpi",    default=600,   type=int, help="DPI de rendu (défaut: 600)")
    parser.add_argument("--pages",  default=None,
                        help="Plage de pages, ex: 1-3 (défaut: tout)")
    parser.add_argument("--snap",   default=None,  help="Chemin racine du snap")
    parser.add_argument("--no-cache", action="store_true",
                        help="Désactiver le cache de traduction")
    args = parser.parse_args()

    # Résolution des chemins
    input_path = Path(args.input).resolve()
    out_root   = Path(args.out).resolve()

    if not input_path.exists():
        sys.exit(f"ERREUR : {input_path} n'existe pas")

    snap_root = Path(args.snap) if args.snap else SNAP_ROOT
    if not snap_root.exists():
        sys.exit(
            f"ERREUR : snap introuvable à {snap_root}\n"
            "Installez le snap ou utilisez --snap pour spécifier le chemin."
        )

    python_bin = find_python312(args.snap)
    env        = build_python_env(snap_root)
    models_dir = get_translation_models_dir(snap_root)

    print(f"Python   : {python_bin}")
    print(f"Pyenv    : {snap_root / 'pyenv'}")
    print(f"Modèles  : {models_dir}")
    print(f"Scripts  : {SCRIPTS_SRC}")

    # Plage de pages
    page_range = None
    if args.pages:
        parts = args.pages.split("-")
        if len(parts) == 2:
            page_range = (int(parts[0]), int(parts[1]))
        elif len(parts) == 1:
            n = int(parts[0])
            page_range = (n, n)
        else:
            sys.exit(f"Format --pages invalide: {args.pages} (attendu: N ou N-M)")

    # Collecte des PDFs
    if input_path.is_dir():
        pdfs = sorted(input_path.glob("*.pdf")) + sorted(input_path.glob("*.PDF"))
        if not pdfs:
            sys.exit(f"Aucun PDF trouvé dans {input_path}")
        print(f"\n{len(pdfs)} PDF(s) trouvé(s) dans {input_path}")
    else:
        pdfs = [input_path]

    out_root.mkdir(parents=True, exist_ok=True)

    all_stats = []
    t0 = time.time()
    for pdf in pdfs:
        stats = process_pdf(
            pdf_path    = pdf,
            src_lang    = args.src,
            tgt_lang    = args.tgt,
            out_root    = out_root,
            dpi         = args.dpi,
            page_range  = page_range,
            python_bin  = python_bin,
            env         = env,
            models_dir  = models_dir,
            use_cache   = not args.no_cache,
        )
        all_stats.append(stats)

    # Résumé global
    total_pages    = sum(s["pages_processed"] for s in all_stats)
    total_blocks   = sum(s["total_blocks"] for s in all_stats)
    total_empty    = sum(s["empty_translations"] for s in all_stats)
    total_errors   = sum(len(s["errors"]) for s in all_stats)
    total_sev_ov   = sum(s.get("total_overlaps_severe", 0) for s in all_stats)
    total_mod_ov   = sum(s.get("total_overlaps_moderate", 0) for s in all_stats)
    elapsed = time.time() - t0

    print(f"\n{'='*60}")
    print(f"RÉSUMÉ GLOBAL")
    print(f"  PDFs traités       : {len(all_stats)}")
    print(f"  Pages              : {total_pages}")
    print(f"  Blocs              : {total_blocks}")
    print(f"  Trad. vides        : {total_empty}")
    print(f"  Chevauch. sévères  : {total_sev_ov}  (IoU>0.30)")
    print(f"  Chevauch. modérés  : {total_mod_ov}  (IoU 0.10–0.30)")
    print(f"  Erreurs            : {total_errors}")
    print(f"  Durée              : {elapsed:.1f}s")
    print(f"  Sorties      : {out_root}/")
    if total_errors:
        print("\nPDFs avec erreurs :")
        for s in all_stats:
            if s["errors"]:
                print(f"  {Path(s['pdf']).name}")
                for e in s["errors"]:
                    print(f"    {e}")


if __name__ == "__main__":
    main()
