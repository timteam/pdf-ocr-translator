#!/usr/bin/env python3
"""
CLI pipeline pour pdf-ocr-translator — OCR + traduction sans IHM Flutter.

Usage :
  python3 scripts/cli_pipeline.py [options] <input>

Arguments :
  <input>    Fichier PDF ou répertoire contenant des PDFs

Options :
  --src LANG   Langue source BCP-47 (défaut: auto)
  --tgt LANG   Langue cible (défaut: fr)
  --out DIR    Répertoire de sortie (défaut: ./cli_output)
  --dpi N      DPI de rendu (défaut: 600)
  --pages A-B  Pages A à B (1-indexé, ex: --pages 1-3)
  --snap PATH  Chemin du snap
  --no-cache   Désactiver le cache de traduction

Sorties par PDF :
  <out>/<pdf_stem>/page_N_ocr.json
  <out>/<pdf_stem>/page_N_translated.json
  <out>/<pdf_stem>/page_N_report.txt      — rapport qualité détaillé
  <out>/<pdf_stem>/page_N_paddle.log
  <out>/<pdf_stem>/page_N_translate.log
  <out>/<pdf_stem>/summary.txt
"""

import argparse
import json
import os
import re
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


def find_python312(snap_override=None):
    if snap_override:
        snap = Path(snap_override)
        gnome = snap.parent.parent / "gnome-46-2404" / "current"
        candidate = gnome / "usr" / "bin" / "python3.12"
        if candidate.exists():
            return candidate
    if PYTHON312.exists():
        return PYTHON312
    found = shutil.which("python3.12")
    if found:
        return Path(found)
    sys.exit("ERREUR : python3.12 introuvable.")


def build_python_env(snap_root=None):
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
    env["SNAP"] = str(root)
    return env


def get_translation_models_dir(snap_root=None):
    return (snap_root or SNAP_ROOT) / "data" / "flutter_assets" / "assets" / "translation_models"


def required_model_dirs(src, tgt):
    if src == tgt:
        return []
    if src == "en":
        return [f"en-{tgt}"]
    if tgt == "en":
        return [f"{src}-en"]
    return [f"{src}-en", f"en-{tgt}"]


# ─── Rendu PDF ────────────────────────────────────────────────────────────────

def get_page_count(pdf_path):
    result = subprocess.run(
        ["pdfinfo", str(pdf_path)], capture_output=True, text=True, check=True
    )
    m = re.search(r"Pages:\s+(\d+)", result.stdout)
    return int(m.group(1)) if m else 1


def render_page(pdf_path, page, dpi, out_dir):
    prefix = out_dir / f"page_{page}"
    subprocess.run(
        ["pdftoppm", "-r", str(dpi), "-png", "-f", str(page), "-l", str(page),
         str(pdf_path), str(prefix)],
        check=True, capture_output=True,
    )
    candidates = sorted(out_dir.glob(f"page_{page}*.png"))
    if not candidates:
        raise FileNotFoundError(f"pdftoppm n'a produit aucun PNG pour la page {page}")
    return candidates[-1]


# ─── OCR ──────────────────────────────────────────────────────────────────────

def ocr_page(image_path, lang, python_bin, env):
    script = SCRIPTS_SRC / "paddle_runner.py"
    result = subprocess.run(
        [str(python_bin), str(script), "ocr", str(image_path), lang],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"paddle_runner.py échoué (exit {result.returncode}):\n{result.stderr}")
    return json.loads(result.stdout), result.stderr


def detect_language(image_path, python_bin, env):
    script = SCRIPTS_SRC / "paddle_runner.py"
    result = subprocess.run(
        [str(python_bin), str(script), "detect", str(image_path)],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return "en"
    data = json.loads(result.stdout)
    script_name = data.get("script", "latin")
    text = data.get("text", "")
    SCRIPT_MAP = {
        "japanese": "ja", "cjk": "zh", "korean": "ko",
        "arabic": "ar", "cyrillic": "ru", "devanagari": "hi", "thai": "th",
    }
    if script_name in SCRIPT_MAP:
        return SCRIPT_MAP[script_name]
    if len(text.strip()) < 20:
        return "en"
    ft_script = SCRIPTS_SRC / "fasttext_detect.py"
    ft_model  = MODELS_SRC / "lid.176.ftz"
    ft_result = subprocess.run(
        [str(python_bin), str(ft_script), str(ft_model)],
        input=text[:1000], capture_output=True, text=True, env=env,
    )
    label = ft_result.stdout.strip().split("\n")[0].strip()
    if label.startswith("__label__"):
        code = label[len("__label__"):]
        supported = {"en","fr","de","es","it","pt","nl","pl","vi","ja","zh","ko","ru","ar","hi","th"}
        if code in supported:
            return code
    return "en"


# ─── Traduction ───────────────────────────────────────────────────────────────

def translate_blocks(texts, src, tgt, python_bin, env, models_dir, cache=None):
    if not texts or src == tgt:
        return list(texts), ""
    model_dirs = required_model_dirs(src, tgt)
    if not model_dirs:
        return list(texts), ""
    for d in model_dirs:
        model_bin = models_dir / d / "model" / "model.bin"
        if not model_bin.exists():
            raise FileNotFoundError(f"Modèle manquant : {model_bin}")
    model_paths = [str(models_dir / d) for d in model_dirs]
    script = SCRIPTS_SRC / "opusmt_translate.py"

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
        input=json.dumps(batch), capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(f"opusmt_translate.py échoué:\n{result.stderr}")

    translated_batch = json.loads(result.stdout)
    for idx, translated in zip(to_translate_indices, translated_batch):
        results[idx] = translated
        if cache is not None:
            cache[texts[idx]] = translated

    return results, result.stderr


# ─── Métriques qualité ────────────────────────────────────────────────────────

def parse_ocr_log_metrics(log: str) -> dict:
    """Extrait les métriques structurées du stderr paddle_runner.py."""
    m = {}
    for line in log.split('\n'):
        # qualité image
        r = re.search(r'contrast=([\d.]+)\s+laplacian=([\d.]+)', line)
        if r:
            m['contrast'] = float(r.group(1))
            m['laplacian'] = float(r.group(2))
        # dimensions image
        r = re.search(r'image dims[:\s]+(\d+)[x×](\d+)', line, re.IGNORECASE)
        if r:
            m['img_w'] = int(r.group(1))
            m['img_h'] = int(r.group(2))
        # ensemble trigger
        r = re.search(r'ensemble trigger.*avg_conf=([\d.]+).*low_conf=(\d+)/(\d+).*run=(\w+)', line)
        if r:
            m['ens_avg_conf'] = float(r.group(1))
            m['ens_low_n'] = int(r.group(2))
            m['ens_total_n'] = int(r.group(3))
            m['ens_triggered'] = (r.group(4) == 'True')
        # blocs après ensemble
        r = re.search(r'(\d+)\s+blocs\s+après\s+ensemble', line)
        if r:
            m['ens_after'] = int(r.group(1))
        # garbage filter
        r = re.search(r'garbage_filter\s*:\s*(\d+)\s*→\s*(\d+).*\((\d+)\s*rejetés', line)
        if r:
            m['garbage_before'] = int(r.group(1))
            m['garbage_after'] = int(r.group(2))
            m['garbage_rejected'] = int(r.group(3))
        # dedup
        r = re.search(r'dedup:\s*(\d+)\s*→\s*(\d+)\s*blocs', line)
        if r:
            m['dedup_before'] = int(r.group(1))
            m['dedup_after'] = int(r.group(2))
    return m


def parse_translate_log_metrics(log: str) -> dict:
    """Extrait les métriques structurées du stderr opusmt_translate.py."""
    m = {'pa2_splits': 0, 'pa3_fallbacks': 0, 'passthrough': 0, 'product_passthrough': 0}
    for line in log.split('\n'):
        r = re.search(r'(\d+)\s+segment.*passthrough', line)
        if r:
            m['passthrough'] = int(r.group(1))
        r = re.search(r'PA2:\s*(\d+)\s+sous-segment', line)
        if r:
            m['pa2_splits'] = int(r.group(1))
        r = re.search(r'PA3:\s*(\d+)\s+segment', line)
        if r:
            m['pa3_fallbacks'] = int(r.group(1))
        r = re.search(r'\[STATS\].*product_pass=(\d+)', line)
        if r:
            m['product_passthrough'] = int(r.group(1))
    return m


def _char_breakdown(text: str) -> dict:
    """Répartition des types de caractères dans un texte."""
    if not text:
        return {'cjk': 0, 'alpha': 0, 'digit': 0, 'punct': 0}
    n = len(text)
    cjk = alpha = digit = punct = 0
    for c in text:
        cp = ord(c)
        if (0x3040 <= cp <= 0x30FF or 0xFF65 <= cp <= 0xFF9F or
                0x4E00 <= cp <= 0x9FFF or 0x3400 <= cp <= 0x4DBF):
            cjk += 1
        elif c.isalpha():
            alpha += 1
        elif c.isdigit():
            digit += 1
        elif not c.isspace():
            punct += 1
    return {
        'cjk':   int(cjk / n * 100),
        'alpha': int(alpha / n * 100),
        'digit': int(digit / n * 100),
        'punct': int(punct / n * 100),
    }


def _conf_bar(conf: float, width: int = 8) -> str:
    filled = round(conf * width)
    return '█' * filled + '░' * (width - filled)


def confidence_stats(blocks: list) -> dict:
    """Distribution de confiance : avg, P25/P50/P75, comptages par zone."""
    if not blocks:
        return {}
    confs = sorted(b.get('confidence', 0.0) for b in blocks)
    n = len(confs)
    return {
        'n':      n,
        'avg':    round(sum(confs) / n, 3),
        'p25':    round(confs[max(0, n // 4 - 1)], 3),
        'p50':    round(confs[n // 2], 3),
        'p75':    round(confs[min(n-1, 3 * n // 4)], 3),
        'min':    round(confs[0], 3),
        'max':    round(confs[-1], 3),
        'n_low':  sum(1 for c in confs if c < 0.60),
        'n_med':  sum(1 for c in confs if 0.60 <= c < 0.80),
        'n_high': sum(1 for c in confs if c >= 0.80),
    }


def translation_quality_metrics(blocks: list, translations: list) -> dict:
    """Métriques qualité de traduction pour une page."""
    if not blocks:
        return {}
    total = len(blocks)
    identity = q_blocks = high_ratio_count = cjk_translated = 0
    ratios = []
    bad_q_list = []
    bad_ratio_list = []

    for blk, trad in zip(blocks, translations):
        src = blk.get('text', '')
        if src.strip() == trad.strip():
            identity += 1
        if '?' in trad and trad != src:
            q_blocks += 1
            bad_q_list.append({
                'src': src[:50], 'tgt': trad[:50],
                'conf': round(blk.get('confidence', 0), 2),
            })
        src_nsp = src.replace(' ', '')
        tgt_nsp = trad.replace(' ', '')
        if len(src_nsp) > 3:
            r = len(tgt_nsp) / len(src_nsp)
            ratios.append(r)
            if r > 3.5:
                high_ratio_count += 1
                bad_ratio_list.append({
                    'ratio': round(r, 1),
                    'src': src[:40], 'tgt': trad[:40],
                })
        src_cjk = sum(1 for c in src if 0x3040 <= ord(c) <= 0x9FFF)
        tgt_latin = sum(1 for c in trad if c.isalpha() and ord(c) < 0x300)
        if src_cjk >= 2 and tgt_latin >= 3 and src.strip() != trad.strip():
            cjk_translated += 1

    bad_ratio_list.sort(key=lambda x: -x['ratio'])
    bad_q_list.sort(key=lambda x: x['conf'])

    return {
        'total':           total,
        'identity':        identity,
        'q_blocks':        q_blocks,
        'cjk_translated':  cjk_translated,
        'high_ratio':      high_ratio_count,
        'avg_ratio':       round(sum(ratios) / len(ratios), 2) if ratios else 0.0,
        'max_ratio':       round(max(ratios), 2) if ratios else 0.0,
        '_bad_q':          bad_q_list[:5],
        '_bad_ratio':      bad_ratio_list[:5],
    }


def detect_page_type(blocks: list) -> str:
    """Heuristique : type de page basé sur la distribution des blocs."""
    if not blocks:
        return "vide"
    n = len(blocks)
    texts = [b.get('text', '') for b in blocks]
    avg_len = sum(len(t) for t in texts) / n if n else 0
    all_text = ' '.join(texts)
    digits = sum(1 for c in all_text if c.isdigit())
    total_chars = len(all_text.replace(' ', '')) or 1
    digit_ratio = digits / total_chars
    widths = [b.get('right', 0) - b.get('left', 0) for b in blocks]
    avg_w = sum(widths) / n if n else 0

    if n > 40 and avg_len < 10 and digit_ratio > 0.25:
        return "tableau_spec"
    if n > 50 and avg_w < 700:
        return "index"
    if avg_len < 15 and n > 20:
        return "diagramme"
    return "texte"


# ─── Analyse de placement ─────────────────────────────────────────────────────

def _box_iou(a: dict, b: dict) -> float:
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


def analyse_layout(blocks: list, page: int) -> dict:
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
    severe   = [o for o in overlaps if o["iou"] > 0.30]
    moderate = [o for o in overlaps if 0.10 < o["iou"] <= 0.30]
    return {
        "page":              page,
        "n_blocks":          n,
        "overlaps_severe":   len(severe),
        "overlaps_moderate": len(moderate),
        "worst_iou":         overlaps[0]["iou"] if overlaps else 0.0,
        "details":           overlaps[:10],
    }


# ─── Rapport par page ─────────────────────────────────────────────────────────

def write_page_report(
    page, lang_src, lang_tgt,
    ocr_blocks, translations,
    out_dir, timings,
    ocr_log="", translate_log="",
) -> tuple:
    """Écrit le rapport qualité détaillé. Retourne (layout, quality_metrics)."""
    layout       = analyse_layout(ocr_blocks, page)
    ocr_m        = parse_ocr_log_metrics(ocr_log)
    trad_m       = parse_translate_log_metrics(translate_log)
    conf_s       = confidence_stats(ocr_blocks)
    tq           = translation_quality_metrics(ocr_blocks, translations)
    page_type    = detect_page_type(ocr_blocks)

    # ── En-tête ───────────────────────────────────────────────────────────────
    render_t  = timings.get('render', 0)
    ocr_t     = timings.get('ocr', 0)
    trad_t    = timings.get('translate', 0)

    lines = [
        f"=== Page {page} | {lang_src} → {lang_tgt} | type={page_type} ===",
        f"Temps      : Rendu={render_t:.1f}s  OCR={ocr_t:.1f}s  Trad={trad_t:.1f}s",
        "",
    ]

    # Image
    img_parts = []
    if 'img_w' in ocr_m:
        img_parts.append(f"{ocr_m['img_w']}×{ocr_m['img_h']}px")
    if 'contrast' in ocr_m:
        img_parts.append(f"contraste={ocr_m['contrast']:.1f}")
    if 'laplacian' in ocr_m:
        img_parts.append(f"laplacian={ocr_m['laplacian']:.0f}")
    if img_parts:
        lines.append(f"Image      : {' | '.join(img_parts)}")

    # OCR confiance
    if conf_s:
        ens_str = ""
        if 'ens_triggered' in ocr_m:
            trig = ocr_m['ens_triggered']
            if trig:
                ens_str = (f" | ensemble=OUI (avg={ocr_m.get('ens_avg_conf',0):.2f}, "
                           f"{ocr_m.get('ens_low_n',0)}/{ocr_m.get('ens_total_n',0)} low)")
            else:
                ens_str = " | ensemble=NON"
        lines.append(
            f"OCR conf   : {conf_s['n']} blocs | "
            f"avg={conf_s['avg']:.2f} P25={conf_s['p25']:.2f} "
            f"P50={conf_s['p50']:.2f} P75={conf_s['p75']:.2f}"
            f"{ens_str}"
        )
        lines.append(
            f"Confiance  : <60%={conf_s['n_low']}  60-80%={conf_s['n_med']}  ≥80%={conf_s['n_high']} blocs"
        )
    if ocr_m.get('garbage_rejected', 0):
        lines.append(f"Garbage    : {ocr_m['garbage_rejected']} blocs rejetés "
                     f"({ocr_m.get('garbage_before',0)} avant → {ocr_m.get('garbage_after',0)})")
    if ocr_m.get('dedup_before'):
        removed = ocr_m['dedup_before'] - ocr_m.get('dedup_after', ocr_m['dedup_before'])
        if removed:
            lines.append(f"Dédup IoU  : {removed} doublons supprimés")

    # Char breakdown global
    all_text = ' '.join(b.get('text', '') for b in ocr_blocks)
    cb = _char_breakdown(all_text)
    if cb['cjk'] > 0 or cb['digit'] > 0:
        lines.append(
            f"Chars      : CJK={cb['cjk']}%  α={cb['alpha']}%  #={cb['digit']}%  ponct={cb['punct']}%"
        )

    # Traduction
    if tq:
        lines.append(
            f"Traduction : {tq['cjk_translated']}/{tq['total']} CJK→Latin | "
            f"identiques={tq['identity']} | "
            f"PA3={trad_m.get('pa3_fallbacks',0)} | "
            f"passthrough={trad_m.get('passthrough',0)} | "
            f"codes-produit={trad_m.get('product_passthrough',0)} | "
            f"'?'-blocs={tq['q_blocks']}"
        )
        lines.append(
            f"Ratios lon.: avg={tq['avg_ratio']}×  max={tq['max_ratio']}×  "
            f">3.5×: {tq['high_ratio']} blocs"
        )

    # Layout
    lines.append(
        f"Layout     : sévères={layout['overlaps_severe']}  "
        f"modérés={layout['overlaps_moderate']}  "
        f"pire IoU={layout['worst_iou']:.2f}"
    )
    lines.append("")

    # Alertes qualité
    if tq.get('_bad_q'):
        lines.append("⚠ Blocs avec '?' dans la traduction :")
        for w in tq['_bad_q']:
            lines.append(f"  [conf={w['conf']}] SRC: {w['src']}")
            lines.append(f"              TGT: {w['tgt']}")
        lines.append("")

    if tq.get('_bad_ratio') and tq.get('max_ratio', 0) > 4.0:
        lines.append("⚠ Ratios longueur extrêmes (>4×) :")
        for w in tq['_bad_ratio']:
            if w['ratio'] > 4.0:
                lines.append(f"  {w['ratio']}×  «{w['src']}» → «{w['tgt']}»")
        lines.append("")

    if layout["overlaps_severe"]:
        lines.append("⚠ CHEVAUCHEMENTS SÉVÈRES (IoU>0.30) :")
        for o in layout["details"]:
            if o["iou"] > 0.30:
                lines.append(f"  Blocs {o['i']+1}↔{o['j']+1}  IoU={o['iou']:.2f}"
                             f"  «{o['text_i']}» ↔ «{o['text_j']}»")
        lines.append("")

    # ── Détail par bloc ───────────────────────────────────────────────────────
    for i, (blk, trad) in enumerate(zip(ocr_blocks, translations)):
        left   = blk.get("left",   0)
        top    = blk.get("top",    0)
        right  = blk.get("right",  0)
        bottom = blk.get("bottom", 0)
        bb     = f"[{left:.0f},{top:.0f} {right-left:.0f}×{bottom-top:.0f}px]"
        orig   = blk.get("text", "")
        conf   = blk.get("confidence", 0.0)
        bar    = _conf_bar(conf)

        # Char breakdown du bloc
        cb_blk = _char_breakdown(orig)
        cb_str = ""
        if cb_blk['cjk'] > 0:
            cb_str += f"CJK={cb_blk['cjk']}%"
        if cb_blk['alpha'] > 5:
            cb_str += f" α={cb_blk['alpha']}%"
        if cb_blk['digit'] > 10:
            cb_str += f" #={cb_blk['digit']}%"

        # Ratio src/tgt
        src_nsp = orig.replace(' ', '')
        tgt_nsp = trad.replace(' ', '')
        ratio_str = ""
        if len(src_nsp) > 3 and len(tgt_nsp) > 0:
            ratio = len(tgt_nsp) / len(src_nsp)
            if ratio > 2.5 or ratio < 0.3:
                ratio_str = f"  [{ratio:.1f}×]"

        identity_str = "  [=src]" if orig.strip() == trad.strip() else ""
        conf_warn    = " !" if conf < 0.60 else ""

        bloc_header = (f"─── Bloc {i+1:02d} (conf={conf:.2f}{conf_warn}) [{bar}] {bb}"
                       + (f" {cb_str}" if cb_str else ""))
        lines += [
            bloc_header,
            f"  SRC : {orig}",
            f"  TGT : {trad}{ratio_str}{identity_str}",
            "",
        ]

    (out_dir / f"page_{page}_report.txt").write_text("\n".join(lines), encoding="utf-8")
    return layout, {
        'conf_stats': conf_s,
        'tq': tq,
        'ocr_metrics': ocr_m,
        'trad_metrics': trad_m,
        'page_type': page_type,
    }


# ─── Pipeline par PDF ─────────────────────────────────────────────────────────

def process_pdf(
    pdf_path, src_lang, tgt_lang, out_root, dpi, page_range,
    python_bin, env, models_dir, use_cache,
):
    stem    = pdf_path.stem
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
        # Métriques qualité agrégées
        "agg_conf_n": 0,
        "agg_conf_sum": 0.0,
        "agg_conf_low": 0,
        "agg_cjk_translated": 0,
        "agg_q_blocks": 0,
        "agg_pa3_fallbacks": 0,
        "agg_passthrough": 0,
        "agg_product_passthrough": 0,
        "agg_garbage_rejected": 0,
        "agg_high_ratio": 0,
        "agg_identity": 0,
        "agg_ens_triggered": 0,
    }
    translation_cache = {} if use_cache else None
    t0_total = time.time()

    for page in range(p_start, p_end + 1):
        print(f"\n  Page {page}/{p_end}")

        with tempfile.TemporaryDirectory(prefix="cli_pdf_") as tmp:
            tmp_path = Path(tmp)
            timings  = {}

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

            # ── Détection langue ─────────────────────────────────────────
            effective_src = src_lang
            if src_lang == "auto":
                print(f"    Détection langue…", end=" ", flush=True)
                effective_src = detect_language(img_path, python_bin, env)
                print(effective_src)

            # ── OCR ─────────────────────────────────────────────────────
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

            (out_dir / f"page_{page}_paddle.log").write_text(paddle_log, encoding="utf-8")
            (out_dir / f"page_{page}_ocr.json").write_text(
                json.dumps(ocr_blocks, ensure_ascii=False, indent=2), encoding="utf-8"
            )

            # ── Traduction ───────────────────────────────────────────────
            # Gate : blocs courts (≤5 chars utiles) à faible confiance (<0.65)
            # produisent systématiquement du bruit en traduction.
            # On les conserve tels quels plutôt que de risquer une mauvaise trad.
            _CONF_MIN_SHORT = 0.65
            _LEN_MAX_SHORT  = 5
            texts        = [b["text"] for b in ocr_blocks]
            translations = list(texts)  # défaut : passthrough
            translate_log = ""

            # Indices à traduire (exclu les blocs courts low-conf)
            skip_low_conf = set()
            for _i, _b in enumerate(ocr_blocks):
                _nsp = _b["text"].replace(' ', '')
                if (len(_nsp) <= _LEN_MAX_SHORT and
                        _b.get("confidence", 1.0) < _CONF_MIN_SHORT):
                    skip_low_conf.add(_i)

            if texts and effective_src != tgt_lang:
                print(f"    Traduction {effective_src}→{tgt_lang} ({len(texts)} seg)…",
                      end=" ", flush=True)
                t = time.time()
                try:
                    # Soumet uniquement les blocs non filtrés
                    texts_filtered = [
                        t if i not in skip_low_conf else ""
                        for i, t in enumerate(texts)
                    ]
                    translated_all, translate_log = translate_blocks(
                        texts_filtered, effective_src, tgt_lang, python_bin, env, models_dir,
                        cache=translation_cache,
                    )
                    # Réintègre les blocs filtrés (gardent leur texte source)
                    translations = [
                        texts[i] if i in skip_low_conf else translated_all[i]
                        for i in range(len(texts))
                    ]
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

            # ── Sauvegarde ───────────────────────────────────────────────
            empty = 0
            result_blocks = []
            for blk, trad in zip(ocr_blocks, translations):
                if not trad.strip():
                    empty += 1
                result_blocks.append({**blk, "translation": trad})

            (out_dir / f"page_{page}_translated.json").write_text(
                json.dumps(result_blocks, ensure_ascii=False, indent=2), encoding="utf-8"
            )

            layout, quality = write_page_report(
                page, effective_src, tgt_lang,
                ocr_blocks, translations, out_dir, timings,
                ocr_log=paddle_log, translate_log=translate_log,
            )

            # Accumulation métriques
            cs  = quality.get('conf_stats', {})
            tq  = quality.get('tq', {})
            om  = quality.get('ocr_metrics', {})
            tm  = quality.get('trad_metrics', {})

            stats["pages_processed"]         += 1
            stats["total_blocks"]            += len(ocr_blocks)
            stats["empty_translations"]      += empty
            stats["total_overlaps_severe"]   += layout["overlaps_severe"]
            stats["total_overlaps_moderate"] += layout["overlaps_moderate"]
            stats["agg_conf_n"]              += cs.get('n', 0)
            stats["agg_conf_sum"]            += cs.get('avg', 0) * cs.get('n', 0)
            stats["agg_conf_low"]            += cs.get('n_low', 0)
            stats["agg_cjk_translated"]      += tq.get('cjk_translated', 0)
            stats["agg_q_blocks"]            += tq.get('q_blocks', 0)
            stats["agg_pa3_fallbacks"]       += tm.get('pa3_fallbacks', 0)
            stats["agg_passthrough"]         += tm.get('passthrough', 0)
            stats["agg_product_passthrough"] += tm.get('product_passthrough', 0)
            stats["agg_garbage_rejected"]    += om.get('garbage_rejected', 0)
            stats["agg_high_ratio"]          += tq.get('high_ratio', 0)
            stats["agg_identity"]            += tq.get('identity', 0)
            if om.get('ens_triggered'):
                stats["agg_ens_triggered"]   += 1

            duration = sum(timings.values())
            overlap_warn = (f" | ⚠ {layout['overlaps_severe']} chevauch. sévères"
                           if layout["overlaps_severe"] else "")
            conf_info = f" | conf_avg={cs.get('avg', 0):.2f}" if cs else ""
            cjk_info  = (f" | CJK→Latin={tq['cjk_translated']}/{tq['total']}"
                        if tq else "")
            print(f"    → {len(ocr_blocks)} blocs | {duration:.1f}s"
                  f"{conf_info}{cjk_info}{overlap_warn}")

    stats["timing_total"] = time.time() - t0_total

    # ── Résumé du document ──────────────────────────────────────────────────
    n = stats["agg_conf_n"] or 1
    avg_conf_global = stats["agg_conf_sum"] / n

    summary_lines = [
        f"PDF : {pdf_path}",
        "",
        "── STATISTIQUES DE TRAITEMENT ──────────────────────────────",
        f"Pages traitées    : {stats['pages_processed']} / {p_end - p_start + 1}",
        f"Blocs totaux      : {stats['total_blocks']}",
        f"Durée totale      : {stats['timing_total']:.1f}s",
        "",
        "── MÉTRIQUES QUALITÉ OCR ────────────────────────────────────",
        f"Confiance globale : avg={avg_conf_global:.3f}",
        f"Blocs <60% conf   : {stats['agg_conf_low']} / {stats['agg_conf_n']}",
        f"Garbage rejetés   : {stats['agg_garbage_rejected']} blocs",
        f"Ensemble activé   : {stats['agg_ens_triggered']} page(s) sur {stats['pages_processed']}",
        "",
        "── MÉTRIQUES QUALITÉ TRADUCTION ─────────────────────────────",
        f"CJK→Latin traduits: {stats['agg_cjk_translated']} blocs",
        f"Identiques (=src) : {stats['agg_identity']} blocs",
        f"Blocs avec '?'    : {stats['agg_q_blocks']} blocs",
        f"PA3 fallbacks     : {stats['agg_pa3_fallbacks']} (traduction rejetée→src conservé)",
        f"Passthrough       : {stats['agg_passthrough']} (ASCII/non-japonais)",
        f"Codes produit     : {stats['agg_product_passthrough']} (passthrough chiffres+CJK)",
        f"Ratios >3.5×      : {stats['agg_high_ratio']} blocs",
        f"Trad. vides       : {stats['empty_translations']}",
        "",
        "── MÉTRIQUES PLACEMENT ──────────────────────────────────────",
        f"Chevauch. sévères : {stats['total_overlaps_severe']}  (IoU>0.30)",
        f"Chevauch. modérés : {stats['total_overlaps_moderate']}  (IoU 0.10–0.30)",
    ]
    if stats["errors"]:
        summary_lines += ["", "ERREURS :"] + [f"  - {e}" for e in stats["errors"]]

    (out_dir / "summary.txt").write_text("\n".join(summary_lines), encoding="utf-8")

    print(f"\n  Terminé : {stats['pages_processed']} pages | "
          f"{stats['total_blocks']} blocs | {stats['timing_total']:.1f}s")
    print(f"  Rapports : {out_dir}/")
    return stats


# ─── Point d'entrée ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="CLI pipeline OCR+traduction pour pdf-ocr-translator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("input",     help="Fichier PDF ou répertoire")
    parser.add_argument("--src",     default="auto",        help="Langue source (défaut: auto)")
    parser.add_argument("--tgt",     default="fr",          help="Langue cible (défaut: fr)")
    parser.add_argument("--out",     default="./cli_output", help="Répertoire de sortie")
    parser.add_argument("--dpi",     default=600, type=int, help="DPI de rendu (défaut: 600)")
    parser.add_argument("--pages",   default=None,           help="Plage de pages, ex: 1-3")
    parser.add_argument("--snap",    default=None,           help="Chemin racine du snap")
    parser.add_argument("--no-cache", action="store_true",  help="Désactiver le cache")
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    out_root   = Path(args.out).resolve()

    if not input_path.exists():
        sys.exit(f"ERREUR : {input_path} n'existe pas")

    snap_root = Path(args.snap) if args.snap else SNAP_ROOT
    if not snap_root.exists():
        sys.exit(f"ERREUR : snap introuvable à {snap_root}")

    python_bin = find_python312(args.snap)
    env        = build_python_env(snap_root)
    models_dir = get_translation_models_dir(snap_root)

    print(f"Python   : {python_bin}")
    print(f"Pyenv    : {snap_root / 'pyenv'}")
    print(f"Modèles  : {models_dir}")
    print(f"Scripts  : {SCRIPTS_SRC}")

    page_range = None
    if args.pages:
        parts = args.pages.split("-")
        if len(parts) == 2:
            page_range = (int(parts[0]), int(parts[1]))
        elif len(parts) == 1:
            n = int(parts[0])
            page_range = (n, n)
        else:
            sys.exit(f"Format --pages invalide: {args.pages}")

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
            pdf_path   = pdf,
            src_lang   = args.src,
            tgt_lang   = args.tgt,
            out_root   = out_root,
            dpi        = args.dpi,
            page_range = page_range,
            python_bin = python_bin,
            env        = env,
            models_dir = models_dir,
            use_cache  = not args.no_cache,
        )
        all_stats.append(stats)

    total_pages  = sum(s["pages_processed"] for s in all_stats)
    total_blocks = sum(s["total_blocks"] for s in all_stats)
    total_errors = sum(len(s["errors"]) for s in all_stats)
    total_sev_ov = sum(s.get("total_overlaps_severe", 0) for s in all_stats)
    total_mod_ov = sum(s.get("total_overlaps_moderate", 0) for s in all_stats)
    total_cjk_tr = sum(s.get("agg_cjk_translated", 0) for s in all_stats)
    total_q_blk  = sum(s.get("agg_q_blocks", 0) for s in all_stats)
    total_pa3    = sum(s.get("agg_pa3_fallbacks", 0) for s in all_stats)
    total_garb   = sum(s.get("agg_garbage_rejected", 0) for s in all_stats)
    elapsed      = time.time() - t0

    print(f"\n{'='*60}")
    print(f"RÉSUMÉ GLOBAL")
    print(f"  PDFs traités       : {len(all_stats)}")
    print(f"  Pages              : {total_pages}")
    print(f"  Blocs              : {total_blocks}")
    print(f"  CJK→Latin traduits : {total_cjk_tr}")
    print(f"  Blocs '?'          : {total_q_blk}")
    print(f"  PA3 fallbacks      : {total_pa3}")
    print(f"  Garbage rejetés    : {total_garb}")
    print(f"  Chevauch. sévères  : {total_sev_ov}")
    print(f"  Chevauch. modérés  : {total_mod_ov}")
    print(f"  Erreurs            : {total_errors}")
    print(f"  Durée              : {elapsed:.1f}s")
    print(f"  Sorties      : {out_root}/")
    if total_errors:
        for s in all_stats:
            if s["errors"]:
                for e in s["errors"]:
                    print(f"    {e}")


if __name__ == "__main__":
    main()
