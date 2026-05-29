#!/usr/bin/env python3
"""
Wrapper RapidOCR (ONNX Runtime backend) pour pdf-ocr-translator.

Modes :
  detect <image_path>
      stdout → JSON  {"text": "…", "script": "latin|cjk|japanese|korean|arabic|cyrillic|devanagari|thai"}

  ocr <image_path> <bcp47_lang>
      stdout → JSON  [{"text":"…", "confidence":0.95, "left":10, "top":5, "right":200, "bottom":30}, …]

Préprocessing :
  - CLAHE (Contrast Limited Adaptive Histogram Equalization) pour améliorer le contraste local
  - Adaptive Thresholding (Otsu) pour binarisation intelligente
  - Deskew via OpenCV pour correction d'inclinaison rapide
"""
import sys
import os
import json
import traceback
import io
import numpy as np
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, line_buffering=True, write_through=True)
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, line_buffering=True, write_through=True)


def dbg(msg):
    sys.stderr.write(f"[runner] {msg}\n")


# ── Import conditionnel de OpenCV ───────────────────────────────────────────
try:
    import cv2
    OPENCV_AVAILABLE = True
except ImportError:
    OPENCV_AVAILABLE = False
    dbg("OpenCV non disponible — préprocessing désactivé")


dbg("démarrage")


# =============================================================================
# PRÉPROCESSING ADAPTATIF POUR RAPIDOCR/PP-OCRv4
#
# Règles déduites du code source RapidOCR 1.4.4 (load_image.py + det utils.py) :
#
#   1. RapidOCR attend du BGR 3 canaux (pas de grayscale).
#      Quand on passe un np.ndarray, il est utilisé tel quel (pas de conversion).
#      Quand on passe un chemin, PIL l'ouvre en RGB puis le convertit BGR.
#
#   2. Normalisation interne détection : (pixel / 255.0 − 0.5) / 0.5 → [-1, 1]
#      → Toute binarisation (Otsu, adaptive) en amont détruirait cette distribution.
#
#   3. Deskew déjà appliqué côté Dart (3 passes, ±85°) — ne pas redoubler.
#
# Pipeline recommandé (adaptatif, uniquement si nécessaire) :
#   • CLAHE sur canal L de LAB si contraste faible (std < 45)
#   • Unsharp masking si flou détecté (Laplacian var < 150)
#   • Retourne np.ndarray BGR ou None (= utiliser l'image originale directement)
# =============================================================================


def preprocess_for_rapidocr(image_path):
    """Préprocessing adaptatif BGR pour RapidOCR. Retourne np.ndarray ou None."""
    if not OPENCV_AVAILABLE:
        return None
    try:
        img = cv2.imread(image_path)  # BGR natif — aucune conversion
        if img is None:
            return None

        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        contrast = float(gray.std())
        laplacian_var = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        dbg(f"qualité image : contrast={contrast:.1f} laplacian={laplacian_var:.0f}")

        modified = False

        # CLAHE sur canal L (LAB) — préserve la couleur, améliore le contraste local
        if contrast < 45:
            lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
            l_ch, a_ch, b_ch = cv2.split(lab)
            clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
            img = cv2.cvtColor(cv2.merge([clahe.apply(l_ch), a_ch, b_ch]),
                               cv2.COLOR_LAB2BGR)
            dbg(f"CLAHE appliqué (contrast {contrast:.1f} < 45)")
            modified = True

        # Unsharp masking — renforce les bords pour DBNet
        if laplacian_var < 150:
            blur = cv2.GaussianBlur(img, (0, 0), 2.0)
            img = cv2.addWeighted(img, 1.5, blur, -0.5, 0)
            dbg(f"unsharp masking appliqué (laplacian {laplacian_var:.0f} < 150)")
            modified = True

        if not modified:
            dbg("image qualité OK — aucun préprocessing externe appliqué")
            return None  # RapidOCR lira l'original directement

        return img  # np.ndarray BGR → passé directement à ocr()

    except Exception as e:
        dbg(f"préprocessing échoué : {e}")
        return None


# ── Localisation des modèles ONNX ─────────────────────────────────────────────
# En contexte snap : $SNAP/data/flutter_assets/assets/models/onnx/
# En contexte local (dev) : flutter_app/assets/models/onnx/
_snap = os.environ.get("SNAP", "")
if _snap:
    MODELS_DIR = Path(_snap) / "data" / "flutter_assets" / "assets" / "models" / "onnx"
else:
    # dev : le script est dans flutter_app/assets/scripts/
    MODELS_DIR = Path(__file__).resolve().parent.parent / "models" / "onnx"

dbg(f"MODELS_DIR={MODELS_DIR}")

# ── Correspondance BCP-47 → clé de modèle ─────────────────────────────────────
LANG_TO_MODEL = {
    "en": "ch",
    "fr": "ch",
    "de": "ch",
    "es": "ch",
    "it": "ch",
    "pt": "ch",
    "nl": "ch",
    "pl": "ch",
    "vi": "ch",
    "ja": "japan",
    "zh": "ch",
    "ko": "korean",
    "ru": "cyrillic",
    "ar": "arabic",
    "hi": "devanagari",
    "th": "thai",
}

# Clés sans rec_model_path utilisent le modèle ch bundlé dans rapidocr_onnxruntime
MODEL_KWARGS = {
    "ch": {},
    "japan": {
        "rec_model_path": str(MODELS_DIR / "japan_rec.onnx"),
        "rec_img_shape": [3, 32, 320],
    },
    "korean": {
        "rec_model_path": str(MODELS_DIR / "korean_rec.onnx"),
    },
    "arabic": {
        "rec_model_path": str(MODELS_DIR / "arabic_rec.onnx"),
    },
    "cyrillic": {
        "rec_model_path": str(MODELS_DIR / "cyrillic_rec.onnx"),
    },
    "devanagari": {
        "rec_model_path": str(MODELS_DIR / "devanagari_rec.onnx"),
    },
    "thai": {
        "rec_model_path": str(MODELS_DIR / "thai_rec.onnx"),
    },
}


def import_rapidocr():
    dbg("import RapidOCR…")
    try:
        from rapidocr_onnxruntime import RapidOCR
        dbg("import OK")
        return RapidOCR
    except Exception as e:
        dbg(f"import FAILED: {e}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(f"rapidocr import failed: {e}")


def make_ocr(model_key):
    dbg(f"make_ocr({model_key})…")
    RapidOCR = import_rapidocr()
    kwargs = dict(MODEL_KWARGS.get(model_key, {}))
    # Évite pthread_setaffinity_np (non autorisé en confinement snap strict)
    kwargs.setdefault("intra_op_num_threads", os.cpu_count() or 4)
    try:
        ocr = RapidOCR(**kwargs)
        dbg(f"make_ocr({model_key}) OK")
        return ocr
    except Exception as e:
        dbg(f"make_ocr({model_key}) FAILED: {e}")
        traceback.print_exc(file=sys.stderr)
        raise


def result_to_text(result, min_conf=0.4):
    if not result:
        return ""
    parts = []
    for item in result:
        _, text, conf_str = item
        if float(conf_str) >= min_conf and text.strip():
            parts.append(text.strip())
    return " ".join(parts)


def result_to_blocks(result, min_conf=0.5):
    if not result:
        return []
    blocks = []
    for item in result:
        box_points, text, conf_str = item
        conf = float(conf_str)
        if conf < min_conf or not text.strip():
            continue
        xs = [p[0] for p in box_points]
        ys = [p[1] for p in box_points]
        blocks.append({
            "text": text.strip(),
            "confidence": conf,
            "left": min(xs),
            "top": min(ys),
            "right": max(xs),
            "bottom": max(ys),
        })
    return blocks


def detect_dominant_script(text):
    counts = {
        "hiragana": 0, "katakana": 0, "cjk": 0, "hangul": 0,
        "arabic": 0, "cyrillic": 0, "devanagari": 0, "thai": 0,
    }
    total = 0
    for ch in text:
        cp = ord(ch)
        total += 1
        if 0x3040 <= cp <= 0x3096:
            counts["hiragana"] += 1
        elif 0x30A0 <= cp <= 0x30FF:
            counts["katakana"] += 1
        elif (0x4E00 <= cp <= 0x9FFF) or (0x3400 <= cp <= 0x4DBF):
            counts["cjk"] += 1
        elif 0xAC00 <= cp <= 0xD7AF:
            counts["hangul"] += 1
        elif 0x0600 <= cp <= 0x06FF:
            counts["arabic"] += 1
        elif 0x0400 <= cp <= 0x04FF:
            counts["cyrillic"] += 1
        elif 0x0900 <= cp <= 0x097F:
            counts["devanagari"] += 1
        elif 0x0E00 <= cp <= 0x0E7F:
            counts["thai"] += 1

    if total == 0:
        return "latin"
    t = total
    if counts["hiragana"] + counts["katakana"] > 5:
        return "japanese"
    if counts["cjk"] / t > 0.08:
        return "cjk"
    if counts["hangul"] / t > 0.05:
        return "korean"
    if counts["arabic"] / t > 0.05:
        return "arabic"
    if counts["cyrillic"] / t > 0.05:
        return "cyrillic"
    if counts["devanagari"] / t > 0.05:
        return "devanagari"
    if counts["thai"] / t > 0.05:
        return "thai"
    return "latin"


def is_latin_or_empty(text):
    non_ws = text.replace(" ", "")
    if not non_ws:
        return True
    ascii_alpha = sum(1 for c in non_ws if c.isascii() and c.isalpha())
    return ascii_alpha / len(non_ws) > 0.60


def run_detect(image_path):
    img_input = preprocess_for_rapidocr(image_path) or image_path

    # ── Passe 1 : modèle ch ───────────────────────────────────────────────────
    dbg("passe 1 : ch")
    ocr_ch = make_ocr("ch")
    dbg("passe 1 : predict…")
    res_ch, _ = ocr_ch(img_input)
    dbg("passe 1 : predict OK")
    text_ch = result_to_text(res_ch)
    script_ch = detect_dominant_script(text_ch)
    dbg(f"passe 1 : script={script_ch}")

    if script_ch in ("arabic", "cyrillic", "devanagari", "thai", "korean", "japanese"):
        json.dump({"text": text_ch, "script": script_ch}, sys.stdout, ensure_ascii=False)
        return

    # ── Passe 2 : modèle japan ────────────────────────────────────────────────
    if script_ch == "cjk" or is_latin_or_empty(text_ch):
        dbg("passe 2 : japan")
        ocr_jp = make_ocr("japan")
        dbg("passe 2 : predict…")
        res_jp, _ = ocr_jp(img_input)
        dbg("passe 2 : predict OK")
        text_jp = result_to_text(res_jp)
        script_jp = detect_dominant_script(text_jp)
        dbg(f"passe 2 : script={script_jp}")

        if script_jp == "japanese":
            json.dump({"text": text_jp, "script": "japanese"}, sys.stdout, ensure_ascii=False)
            return

        if script_ch == "cjk":
            json.dump({"text": text_ch, "script": "cjk"}, sys.stdout, ensure_ascii=False)
            return

    # ── Passe 3 : même modèle ch pour le latin ────────────────────────────────
    dbg("passe 3 : latin (ch)")
    json.dump({"text": text_ch, "script": "latin"}, sys.stdout, ensure_ascii=False)


def run_ocr(image_path, bcp47_lang):
    model_key = LANG_TO_MODEL.get(bcp47_lang, "ch")
    dbg(f"run_ocr : lang={bcp47_lang} → model={model_key}")
    # Préprocessing adaptatif : retourne np.ndarray BGR ou None
    # Si None → RapidOCR charge l'original via PIL (légère conversion RGB→BGR interne)
    img_input = preprocess_for_rapidocr(image_path) or image_path
    ocr = make_ocr(model_key)
    dbg("run_ocr : predict…")
    result, _ = ocr(img_input)
    dbg("run_ocr : predict OK")
    blocks = result_to_blocks(result)
    dbg(f"run_ocr : {len(blocks)} blocs")
    json.dump(blocks, sys.stdout, ensure_ascii=False)


def main():
    if len(sys.argv) < 3:
        sys.exit("Usage: paddle_runner.py detect <image> | ocr <image> <bcp47_lang>")

    mode = sys.argv[1]
    image_path = sys.argv[2]

    if not os.path.exists(image_path):
        sys.exit(f"Image introuvable: {image_path}")

    try:
        if mode == "detect":
            run_detect(image_path)
        elif mode == "ocr":
            if len(sys.argv) < 4:
                sys.exit("Usage: paddle_runner.py ocr <image> <bcp47_lang>")
            run_ocr(image_path, sys.argv[3])
        else:
            sys.exit(f"Mode inconnu: {mode}")
    except Exception as e:
        dbg(f"EXCEPTION dans {mode}: {e}")
        traceback.print_exc(file=sys.stderr)
        if mode == "detect":
            json.dump({"text": "", "script": "latin"}, sys.stdout, ensure_ascii=False)
        else:
            json.dump([], sys.stdout, ensure_ascii=False)
        sys.exit(1)

    dbg("terminé")


if __name__ == "__main__":
    main()
