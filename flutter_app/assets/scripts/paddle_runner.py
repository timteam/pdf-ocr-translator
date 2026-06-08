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
import re
import json
import traceback
import io
import unicodedata
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

        # PA8 : inversion des bandes sombres (texte clair sur fond sombre)
        # Détecte les bandes horizontales dont la luminosité moyenne < 80
        # (ex : bannière titre "イセキトラクタ" blanche sur fond noir).
        row_means = np.mean(gray, axis=1)
        dark_mask = row_means < 80
        if np.any(dark_mask):
            in_band, band_start = False, 0
            n_rows = len(dark_mask)
            bands = []
            for ri in range(n_rows):
                if dark_mask[ri] and not in_band:
                    in_band, band_start = True, ri
                elif not dark_mask[ri] and in_band:
                    in_band = False
                    if ri - band_start >= 15:
                        bands.append((band_start, ri))
            if in_band and n_rows - band_start >= 15:
                bands.append((band_start, n_rows))
            if bands:
                img = img.copy()
                for b_start, b_end in bands:
                    img[b_start:b_end] = 255 - img[b_start:b_end]
                    dbg(f"PA8: inversion bande sombre lignes {b_start}–{b_end} "
                        f"({b_end - b_start}px)")
                # Recalcule les métriques après inversion
                gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
                contrast = float(gray.std())
                laplacian_var = float(cv2.Laplacian(gray, cv2.CV_64F).var())
                modified = True

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


# Traits Unicode souvent lus à la place d'un tiret dans les codes produit Iseki
# (ex : "1668一904-007-1" → "1668-904-007-1")
_CJK_DASH_RE = re.compile(
    r'(?<=\d)[一ー―–—－](?=\d)'
)


def _normalize_product_code(text: str) -> str:
    """PA4 : normalise les codes produits alphanumériques.

    Si ratio chiffres/longueur > 55 % et ≥ 2 groupes de 3 chiffres (schéma
    XXXX-XXX-XXX-X), remplace tout séparateur non-alphanumérique entre deux
    chiffres par un tiret. Généralise sans liste de caractères cibles fixe.
    """
    if not text or len(text) < 8:
        return text
    digits = sum(1 for c in text if c.isdigit())
    if digits / len(text) <= 0.55:
        return text
    # Nécessite au moins deux groupes de ≥ 3 chiffres consécutifs (code produit)
    if not re.search(r'\d{3}.\d{3}', text):
        return text
    text = re.sub(r'(?<=\d)[^0-9A-Za-z\s]{1,3}(?=\d)', '-', text)
    text = re.sub(r'-{2,}', '-', text)
    return text


def _normalize_block_text(text: str) -> str:
    """Nettoyage du texte OCR brut avant export.

    - NFKC : convertit fullwidth (ＡＢ→AB, １２→12), ligatures, etc.
    - CJK dashes : remplace les traits CJK entre chiffres par '-'.
    - PA4 : normalise les codes produits à fort ratio de chiffres.
    - PA6 : supprime les artefacts de leaders de points (・・, ·, etc.)
            en tête des blocs contenant des chiffres (références de page d'index).
    """
    text = unicodedata.normalize('NFKC', text)
    text = _CJK_DASH_RE.sub('-', text)
    text = _normalize_product_code(text)
    # PA6 : ・ (U+30FB), · (U+00B7), ‧ (U+2027), ⋅ (U+22C5) en tête d'une
    # référence de page → artefacts OCR des points de conduite (……)
    if re.search(r'\d', text):
        text = re.sub(r'^[・·‧⋅`\'\":\-]+\s*', '', text)
        text = text.strip()
    return text


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
            "text": _normalize_block_text(text.strip()),
            "confidence": conf,
            "left": min(xs),
            "top": min(ys),
            "right": max(xs),
            "bottom": max(ys),
        })
    return blocks


# =============================================================================
# LAYOUT ANALYSIS — fusion spatiale des blocs OCR
#
# DBNet sur-segmente parfois le texte (ex : caractères isolés dans les légendes,
# texte vertical, tableaux). Cette étape regroupe les boîtes voisines qui
# appartiennent à la même ligne de texte avant le filtre garbage côté Dart.
#
# Deux passes :
#   1. Horizontale : même ligne (chevauchement vertical ≥ 40 % de la hauteur min)
#      + gap horizontal ≤ 1,5 × hauteur min → concaténation gauche→droite.
#   2. Verticale  : même colonne (chevauchement horizontal ≥ 30 % de la largeur min)
#      + gap vertical ≤ 1,0 × hauteur du bloc → concaténation haut→bas
#      (utile pour le texte vertical japonais fragmenté).
# =============================================================================

def _merge_pass(blocks, axis, gap_max_ratio, overlap_min_ratio, max_gap_px=None,
                max_result_chars=None, max_result_height_px=None):
    """
    Fusionne les blocs proches sur un axe donné.
    axis='h' → même ligne (merge horizontal) ; axis='v' → même colonne (merge vertical).
    max_gap_px          : limite absolue du gap en pixels (indépendante du ratio).
    max_result_chars    : PA1 — refuse la fusion si le bloc résultant dépasse N caractères.
    max_result_height_px: PA1 — refuse la fusion verticale si la hauteur résultante > N px.
    Utilise les bornes courantes du groupe (chain merging) plutôt que le seul bloc ancre.
    """
    if not blocks:
        return blocks

    if axis == 'h':
        primary_sort  = lambda b: (b['top'],  b['left'])
        primary_size  = lambda b: b['bottom'] - b['top']      # hauteur
        primary_lo    = lambda b: b['top']
        primary_hi    = lambda b: b['bottom']
        secondary_lo  = lambda b: b['left']
        secondary_hi  = lambda b: b['right']
        text_order    = lambda g: sorted(g, key=lambda b: b['left'])
    else:  # 'v'
        primary_sort  = lambda b: (b['left'],  b['top'])
        primary_size  = lambda b: b['right'] - b['left']      # largeur
        primary_lo    = lambda b: b['left']
        primary_hi    = lambda b: b['right']
        secondary_lo  = lambda b: b['top']
        secondary_hi  = lambda b: b['bottom']
        text_order    = lambda g: sorted(g, key=lambda b: b['top'])

    sorted_blocks = sorted(blocks, key=primary_sort)
    used = [False] * len(sorted_blocks)
    groups = []

    for i, b1 in enumerate(sorted_blocks):
        if used[i]:
            continue
        group = [b1]
        used[i] = True

        # Bornes courantes du groupe (chain merging : compare contre le bord du groupe,
        # pas seulement contre le bloc ancre)
        grp_pri_lo  = primary_lo(b1)
        grp_pri_hi  = primary_hi(b1)
        grp_sec_hi  = secondary_hi(b1)

        for j in range(i + 1, len(sorted_blocks)):
            if used[j]:
                continue
            b2 = sorted_blocks[j]
            s2 = primary_size(b2)
            grp_pri_size = grp_pri_hi - grp_pri_lo
            min_s = min(grp_pri_size, s2)

            # Chevauchement sur l'axe principal (contre les bornes actuelles du groupe)
            overlap = min(grp_pri_hi, primary_hi(b2)) - max(grp_pri_lo, primary_lo(b2))
            if overlap < min_s * overlap_min_ratio:
                continue

            # Gap sur l'axe secondaire (contre le bord courant du groupe)
            gap = secondary_lo(b2) - grp_sec_hi
            if gap < 0 or gap > min_s * gap_max_ratio:
                continue
            if max_gap_px is not None and gap > max_gap_px:
                continue

            # PA1 : refuse la fusion si le bloc résultant serait trop grand
            if max_result_chars is not None:
                total_chars = sum(len(b['text']) for b in group) + len(b2['text'])
                if total_chars > max_result_chars:
                    continue
            if max_result_height_px is not None:
                new_hi = max(grp_pri_hi, primary_hi(b2))
                new_lo = min(grp_pri_lo, primary_lo(b2))
                if new_hi - new_lo > max_result_height_px:
                    continue

            group.append(b2)
            used[j] = True
            # Étend les bornes du groupe pour le prochain candidat
            grp_sec_hi = max(grp_sec_hi, secondary_hi(b2))
            grp_pri_lo = min(grp_pri_lo, primary_lo(b2))
            grp_pri_hi = max(grp_pri_hi, primary_hi(b2))

        groups.append(group)

    merged = []
    for group in groups:
        if len(group) == 1:
            merged.append(group[0])
            continue
        ordered = text_order(group)
        sep = '' if axis == 'v' else ' '
        text  = sep.join(b['text'] for b in ordered)
        conf  = min(b['confidence'] for b in ordered)
        merged.append({
            'text':       text,
            'confidence': conf,
            'left':   min(b['left']   for b in ordered),
            'top':    min(b['top']    for b in ordered),
            'right':  max(b['right']  for b in ordered),
            'bottom': max(b['bottom'] for b in ordered),
        })
    return merged


def _is_index_page(blocks):
    """Heuristique : page de type index/table des matières.

    Caractéristiques : beaucoup de petits blocs étroits (termes + numéros de page
    séparés par des points de conduite). Déclenche une passe verticale agressive
    pour regrouper les termes multi-lignes d'un même article d'index.
    """
    if len(blocks) < 30:
        return False
    widths = [b['right'] - b['left'] for b in blocks]
    avg_w = sum(widths) / len(widths)
    narrow = sum(1 for w in widths if w < 700)  # < ~30 mm à 600 DPI
    return narrow / len(widths) > 0.45 and avg_w < 900


def layout_analysis(blocks):
    """
    Applique les deux passes de fusion spatiale et filtre les boîtes trop petites.

    Tuning :
      MIN_AREA      : 2000 px² → élimine fragments sub-caractère à 600 DPI
                      (un caractère japonais ~50×50 px = 2500 px²)
      h gap_max     : 1.5 × hauteur, plafonné à 150 px (~6 mm à 600 DPI)
                      → évite de fusionner des colonnes séparées
      h overlap_min : 0.4 → les deux blocs doivent partager ≥ 40 % de hauteur
      v gap_max     : 1.0 × largeur, plafonné à 80 px (~3 mm à 600 DPI)
      v overlap_min : 0.3 → chevauchement horizontal ≥ 30 % pour texte vertical
    """
    MIN_AREA = 2000  # px² (était 800)

    filtered = [b for b in blocks
                if (b['right'] - b['left']) * (b['bottom'] - b['top']) >= MIN_AREA]

    # Passe 1 : fusion horizontale (même ligne de texte)
    # PA1 : max 150 chars — évite les mega-blocs multi-colonnes
    merged = _merge_pass(filtered,
                         axis='h',
                         gap_max_ratio=1.5,
                         overlap_min_ratio=0.4,
                         max_gap_px=150,
                         max_result_chars=150)

    # Passe 2 : fusion verticale (texte vertical japonais, listes)
    # PA1 : max 120 chars et 350 px de hauteur — bloque la fusion de paragraphes entiers
    merged = _merge_pass(merged,
                         axis='v',
                         gap_max_ratio=1.0,
                         overlap_min_ratio=0.3,
                         max_gap_px=80,
                         max_result_chars=120,
                         max_result_height_px=350)

    # Passe 3 (page index) : fusion verticale complémentaire avec chevauchement strict
    # pour regrouper les entrées d'index fragmentées sur plusieurs lignes.
    if _is_index_page(merged):
        n_before = len(merged)
        merged = _merge_pass(merged,
                             axis='v',
                             gap_max_ratio=0.4,
                             overlap_min_ratio=0.55,
                             max_gap_px=25)
        dbg(f"layout_analysis (index) : passe 3 : {n_before} → {len(merged)}")

    n_in  = len(blocks)
    n_out = len(merged)
    if n_in != n_out:
        dbg(f"layout_analysis : {n_in} blocs → {n_out} après fusion spatiale")

    return merged


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
    _preprocessed = preprocess_for_rapidocr(image_path)
    img_input = _preprocessed if _preprocessed is not None else image_path

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
    _preprocessed = preprocess_for_rapidocr(image_path)
    img_input = _preprocessed if _preprocessed is not None else image_path
    ocr = make_ocr(model_key)
    dbg("run_ocr : predict…")
    result, _ = ocr(img_input)
    dbg("run_ocr : predict OK")
    blocks = result_to_blocks(result)
    dbg(f"run_ocr : {len(blocks)} blocs bruts")
    blocks = layout_analysis(blocks)
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
