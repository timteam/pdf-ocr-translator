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
    """Préprocessing systématique BGR pour RapidOCR. Retourne np.ndarray ou None.

    Pipeline (toujours appliqué pour les documents scannés) :
      1. Filtre bilatéral — débruite sans effacer les contours de texte
      2. CLAHE (16×16 tiles, clipLimit=3) — contraste local fin sur canal L
      3. Unsharp masking — renforce les arêtes pour DBNet
      4. PA8 : inversion des bandes sombres (texte clair sur fond sombre)
    """
    if not OPENCV_AVAILABLE:
        return None
    try:
        img = cv2.imread(image_path)
        if img is None:
            return None

        h_img, w_img = img.shape[:2]
        dbg(f"image dims: {w_img}x{h_img}")
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        contrast = float(gray.std())
        laplacian_var = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        dbg(f"qualité image : contrast={contrast:.1f} laplacian={laplacian_var:.0f}")

        # 1. Filtre bilatéral — débruite tout en préservant les contours de caractères
        img = cv2.bilateralFilter(img, d=5, sigmaColor=80, sigmaSpace=80)
        dbg("filtre bilatéral appliqué")

        # 2. CLAHE systématique sur canal L (LAB) avec tuiles fines (16×16)
        #    Améliore le contraste local même sur des images globalement bien exposées.
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        l_ch, a_ch, b_ch = cv2.split(lab)
        clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(16, 16))
        img = cv2.cvtColor(cv2.merge([clahe.apply(l_ch), a_ch, b_ch]),
                           cv2.COLOR_LAB2BGR)
        dbg("CLAHE(16×16, clip=3) appliqué")

        # 3. Unsharp masking — renforce les bords pour DBNet
        if laplacian_var < 300:
            blur = cv2.GaussianBlur(img, (0, 0), 2.0)
            img = cv2.addWeighted(img, 1.5, blur, -0.5, 0)
            dbg(f"unsharp masking appliqué (laplacian {laplacian_var:.0f} < 300)")

        # 4. PA8 : inversion des bandes sombres
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
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
            for b_start, b_end in bands:
                img[b_start:b_end] = 255 - img[b_start:b_end]
                dbg(f"PA8: inversion bande sombre lignes {b_start}–{b_end}")

        return img

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
    kwargs.setdefault("intra_op_num_threads", os.cpu_count() or 4)
    # Augmente la résolution effective de détection : sans cela, une image 600 DPI
    # (~7000 px de haut) est ramenée à ~170 DPI effectifs avant le détecteur DBNet,
    # ce qui fait rater les petits caractères.
    kwargs["max_side_len"] = 3000
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


# Kanji visuellement similaires à des katakana — source fréquente d'erreur OCR.
# La substitution ne s'applique que si le caractère est encadré par des kana
# (hiragana ou katakana), évitant les faux-positifs dans du texte kanji pur.
# Exemples : トラク夕→トラクタ (tracteur), エンシン→エンジン ne rentre pas ici
_KATA_KANJI = {
    '夕': 'タ',  # 夕→タ (soir → TA)
    '工': 'エ',  # 工→エ (travail → E)
    '口': 'ロ',  # 口→ロ (bouche → RO)
    '力': 'カ',  # 力→カ (force → KA)
    '八': 'ハ',  # 八→ハ (huit → HA)
    '二': 'ニ',  # 二→ニ (deux → NI)
    '一': 'ー',  # 一→ー (un → prolongateur)
    '了': 'フ',  # 了→フ (achèvement → FU, ex: リンク了S→リンクフS)
    '丁': 'テ',  # 丁→テ (bloc → TE, ex: デスク丁→デスクテ)
}
_KANA_RANGE = lambda cp: 0x3040 <= cp <= 0x30FF  # hiragana + katakana


def _fix_katakana_confusion(text: str) -> str:
    """Corrige les confusions kanji↔katakana en contexte kana.

    Ne substitue que si le caractère ambigu est entouré de kana des deux côtés.
    """
    if not any(ch in text for ch in _KATA_KANJI):
        return text
    chars = list(text)
    n = len(chars)
    for i, ch in enumerate(chars):
        if ch not in _KATA_KANJI:
            continue
        prev_kana = i > 0 and _KANA_RANGE(ord(chars[i - 1]))
        # next = kana OU lettre majuscule ASCII (ex: リンク了S → リンクフS)
        nxt = chars[i + 1] if i < n - 1 else ''
        next_kana_or_alpha = (
            (nxt and _KANA_RANGE(ord(nxt))) or
            ('A' <= nxt <= 'Z')
        )
        if prev_kana and next_kana_or_alpha:
            chars[i] = _KATA_KANJI[ch]
    return ''.join(chars)


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
    # Correction de variantes CJK simplifiées OCR courantes :
    # le modèle Opus-MT ja→en est entraîné sur du japonais standard et ne reconnaît pas
    # certains idéogrammes simplifiés chinois parfois lus par le modèle OCR.
    _CJK_VARIANT_FIX = {'别': '別', '説': '説', '発': '発'}
    text = ''.join(_CJK_VARIANT_FIX.get(c, c) for c in text)
    text = _fix_katakana_confusion(text)
    text = _CJK_DASH_RE.sub('-', text)
    text = _normalize_product_code(text)
    # Supprime les guillemets/crochets CJK et backticks isolés en tête ou en fin
    # de bloc — artefacts OCR courants sur les pages avec diagrammes d'étiquettes.
    # Exemples : "1ON」`スイッチを押して" → "1ONスイッチを押して"
    text = re.sub(r'^[「」｢｣`\'"]+', '', text)
    text = re.sub(r'[「」｢｣`\'"]+$', '', text)
    text = text.strip()
    # PA6 : ・ (U+30FB), · (U+00B7), ‧ (U+2027), ⋅ (U+22C5) en tête d'une
    # référence de page → artefacts OCR des points de conduite (……)
    if re.search(r'\d', text):
        text = re.sub(r'^[・·‧⋅`\'\":\-]+\s*', '', text)
        text = text.strip()
    return text


_PRODUCT_CODE_RE = re.compile(
    r'^\d{3,6}[－〜\-\s]{1,3}\d{2,4}[－〜\-\s]{1,3}\d{2,4}([－〜\-\s]{1,3}\d{0,4})?[-]?$'
)

def _is_product_code(text: str) -> bool:
    """Détecte les codes référence produit.
    Ex : 1668-904-007-1, 1675〜-903--004〜0, 16-5-905-012
    """
    t = text.strip()
    digits = sum(1 for c in t if c.isdigit())
    if digits < 4:
        return False
    return bool(_PRODUCT_CODE_RE.match(t))


def result_to_blocks(result, min_conf=0.55):
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

def _detect_table_row_barriers(img) -> list:
    """Détecte les positions Y des lignes horizontales de tableau.

    Utilise l'érosion morphologique pour trouver les traits continus qui s'étendent
    sur au moins 30% de la largeur de l'image. Ces lignes servent de barrières
    dans la passe de fusion horizontale pour éviter de mélanger du texte
    provenant de lignes adjacentes d'un tableau.

    Returns: liste triée des coordonnées Y (pixels) des lignes détectées.
    """
    if not OPENCV_AVAILABLE or img is None:
        return []
    try:
        arr = img if isinstance(img, np.ndarray) else None
        if arr is None:
            arr = cv2.imread(img)
        if arr is None:
            return []
        gray = cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
        H, W = gray.shape
        # Seuil adaptatif pour binarisation
        _, binary = cv2.threshold(gray, 0, 255,
                                  cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        # Noyau : 30% de la largeur × 1 px — détecte les lignes longues
        min_len = max(30, W // 3)
        kern = cv2.getStructuringElement(cv2.MORPH_RECT, (min_len, 1))
        h_lines = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kern)
        # Profil Y : ligne présente si ≥ 20% de la largeur est activée
        h_proj = np.sum(h_lines > 0, axis=1)
        barriers = []
        in_line = False
        line_start = 0
        for y in range(H):
            if h_proj[y] >= W * 0.20 and not in_line:
                in_line, line_start = True, y
            elif h_proj[y] < W * 0.20 and in_line:
                in_line = False
                barriers.append((line_start + y) // 2)
        if in_line:
            barriers.append((line_start + H) // 2)
        dbg(f"tableau : {len(barriers)} ligne(s) H détectée(s) → barrières fusion")
        return barriers
    except Exception as e:
        dbg(f"_detect_table_row_barriers : {e}")
        return []


def _merge_pass(blocks, axis, gap_max_ratio, overlap_min_ratio, max_gap_px=None,
                max_result_chars=None, max_result_height_px=None,
                _row_barriers=None):
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

            # Isolation codes produit : ne jamais fusionner un code référence
            # (ex : 1668-904-007-1) avec du texte adjacent — ils constituent
            # des identifiants autonomes qui ne doivent pas être traduits.
            if _is_product_code(b1['text']) or _is_product_code(b2['text']):
                continue

            # Barrières de tableau : si la fusion croise une ligne horizontale
            # de tableau (row_barriers passé via closure), rejeter.
            if axis == 'h' and _row_barriers:
                b1_mid = (grp_pri_lo + grp_pri_hi) / 2
                b2_mid = (primary_lo(b2) + primary_hi(b2)) / 2
                y_lo, y_hi = min(b1_mid, b2_mid), max(b1_mid, b2_mid)
                if any(y_lo < barrier < y_hi for barrier in _row_barriers):
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


def layout_analysis(blocks, row_barriers=None):
    """
    Applique les deux passes de fusion spatiale et filtre les boîtes trop petites.

    row_barriers : liste triée de coordonnées Y de lignes de tableau.
                   La passe horizontale ne fusionnera pas de blocs situés
                   de part et d'autre d'une de ces lignes.

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
    # Si row_barriers est fourni (tableau structuré), la fusion ne traverse pas
    # les lignes horizontales du tableau → évite les fusions inter-lignes.
    merged = _merge_pass(filtered,
                         axis='h',
                         gap_max_ratio=1.5,
                         overlap_min_ratio=0.4,
                         max_gap_px=150,
                         max_result_chars=150,
                         _row_barriers=row_barriers or [])

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


def _split_wide_blocks_at_boundary(blocks: list) -> list:
    """Divise les blocs larges qui contiennent plusieurs phrases/valeurs.

    DBNet détecte parfois une ligne entière de tableau comme une seule grande
    boîte, produisant des blocs comme "後一輪。 11001420-5段階) 1020-1340-5段í階)".
    Ces blocs multi-éléments traduisent mal. On les divise aux frontières 。/）
    si le bloc dépasse 600px de large ET contient au moins 2 segments.

    Les coordonnées X de chaque sous-bloc sont estimées proportionnellement.
    """
    _WIDE_THRESHOLD = 600  # px — en dessous, pas de split
    result = []
    for b in blocks:
        width = b['right'] - b['left']
        text  = b['text']
        if width < _WIDE_THRESHOLD:
            result.append(b)
            continue
        # Découpe sur 。 suivi d'un espace ou en fin de chaîne
        parts = [p.strip() for p in re.split(r'(?<=。)\s+', text) if p.strip()]
        if len(parts) <= 1:
            result.append(b)
            continue
        # Répartition proportionnelle des coordonnées X
        total_chars = sum(len(p) for p in parts) or 1
        x_cursor = float(b['left'])
        total_width = float(b['right'] - b['left'])
        for part in parts:
            part_w = total_width * len(part) / total_chars
            result.append({
                'text':       part,
                'confidence': b['confidence'],
                'left':       round(x_cursor),
                'top':        b['top'],
                'right':      round(x_cursor + part_w),
                'bottom':     b['bottom'],
            })
            x_cursor += part_w
    n_splits = len(result) - len(blocks)
    if n_splits:
        dbg(f"split_wide : {n_splits} sous-blocs créés depuis {len(blocks)} blocs")
    return result


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


def _is_garbage_block(block: dict) -> bool:
    """Filtre Python miroir de _isGarbageText (Dart) — s'applique avant l'export JSON.

    Élimine les blocs OCR manifestement bruités avant qu'ils n'atteignent le
    moteur de traduction.  Les critères reproduisent les règles Dart les plus
    discriminantes (ratio de caractères significatifs, dominance d'un seul
    caractère, artefacts Latin-1/UTF-8, faux japonais).
    """
    text = block.get('text', '').strip()
    if not text:
        return True

    non_space = text.replace(' ', '')
    if not non_space:
        return True

    # Artefacts double-encodage Latin-1/UTF-8
    if re.search(r'[ãâ][»·\x80-\xBF]|ï¼|ï½', text):
        return True

    # Caractère non-ASCII répété (ex: "金金", "ーー", "いいい")
    # Un bloc de 2–5 chars tous identiques et non-ASCII est un artefact OCR
    if len(set(non_space)) == 1 and 2 <= len(non_space) <= 5:
        ch = non_space[0]
        if ord(ch) > 127:
            return True


    meaningful = 0
    has_japanese = False
    char_freq: dict[str, int] = {}
    for ch in non_space:
        cp = ord(ch)
        char_freq[ch] = char_freq.get(ch, 0) + 1
        if ((0x41 <= cp <= 0x5A) or (0x61 <= cp <= 0x7A) or
                (0x30 <= cp <= 0x39) or
                (0x3040 <= cp <= 0x309F) or (0x30A0 <= cp <= 0x30FF) or
                (0xFF65 <= cp <= 0xFF9F) or (0x4E00 <= cp <= 0x9FFF)):
            meaningful += 1
        if ((0x3040 <= cp <= 0x30FF) or (0xFF65 <= cp <= 0xFF9F) or
                (0x4E00 <= cp <= 0x9FFF)):
            has_japanese = True

    # Faux japonais : uniquement ponctuation CJK, pas de kana/kanji réels
    if has_japanese:
        has_real = any(
            (0x3040 <= ord(c) <= 0x30FA) or (0x30FC <= ord(c) <= 0x30FE) or
            (0xFF65 <= ord(c) <= 0xFF9F) or (0x4E00 <= ord(c) <= 0x9FFF) or
            (0x3400 <= ord(c) <= 0x4DBF)
            for c in non_space
        )
        if not has_real:
            return True

    # Ratio de caractères significatifs
    is_pure_2 = (meaningful == 2 and len(non_space) == 2)
    if not is_pure_2 and meaningful < 3:
        return True
    if (len(non_space) - meaningful) / len(non_space) > 0.4:
        return True

    # Texte commençant par ッ/っ (petit tsu) : toujours un fragment en japonais
    # Le petit tsu ne peut jamais être en position initiale dans un mot japonais
    if non_space[0] in ('ッ', 'っ'):
        return True

    # Non-japonais commençant par un symbole non alphanumérique
    if not has_japanese:
        first = non_space[0]
        if not (first.isalpha() or first.isdigit()):
            return True

    # Dominance d'un seul caractère (> 50 %)
    for ch, cnt in char_freq.items():
        if ch != '.' and cnt > 4 and cnt / len(non_space) > 0.5:
            return True

    # Bloc court (≤5 chars) dominé par un CJK répété (ex: "金金轴" : 金×2/3=67%)
    if 3 <= len(non_space) <= 5:
        for ch, cnt in char_freq.items():
            if cnt >= 2 and ord(ch) > 127 and cnt / len(non_space) > 0.60:
                return True

    # Trop de mots mono-caractère
    words = text.split()
    if len(words) >= 3:
        single_char = sum(1 for w in words if len(w) == 1)
        if single_char / len(words) > 0.6:
            return True

    return False


def _dedup_by_iou(blocks: list, iou_thresh: float = 0.25) -> list:
    """Supprime les blocs redondants par IoU. Garde celui avec la meilleure confiance."""
    keep = [True] * len(blocks)
    for i in range(len(blocks)):
        if not keep[i]:
            continue
        for j in range(i + 1, len(blocks)):
            if not keep[j]:
                continue
            iou = _box_iou(blocks[i], blocks[j])
            if iou > iou_thresh:
                # Garder celui avec la meilleure confiance
                if blocks[i].get('confidence', 0) >= blocks[j].get('confidence', 0):
                    keep[j] = False
                    dbg(f"dedup: drop [{j}] «{blocks[j]['text'][:25]}» (IoU={iou:.2f})")
                else:
                    keep[i] = False
                    dbg(f"dedup: drop [{i}] «{blocks[i]['text'][:25]}» (IoU={iou:.2f})")
                    break
    result = [b for b, k in zip(blocks, keep) if k]
    if len(result) < len(blocks):
        dbg(f"dedup: {len(blocks)} → {len(result)} blocs ({len(blocks)-len(result)} doublons)")
    return result


def _japanese_ratio(text: str) -> float:
    """Fraction de caractères japonais/CJK dans le texte."""
    if not text:
        return 0.0
    jp = sum(1 for c in text if (
        0x3040 <= ord(c) <= 0x30FF or
        0xFF65 <= ord(c) <= 0xFF9F or
        0x4E00 <= ord(c) <= 0x9FFF
    ))
    return jp / len(text)


def _box_iou(a: dict, b: dict) -> float:
    """IoU entre deux bounding boxes."""
    ix1 = max(a['left'],   b['left'])
    iy1 = max(a['top'],    b['top'])
    ix2 = min(a['right'],  b['right'])
    iy2 = min(a['bottom'], b['bottom'])
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    inter = (ix2 - ix1) * (iy2 - iy1)
    area_a = (a['right'] - a['left']) * (a['bottom'] - a['top'])
    area_b = (b['right'] - b['left']) * (b['bottom'] - b['top'])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def _ensemble_blocks(blocks_primary: list, blocks_secondary: list,
                     iou_thresh: float = 0.35) -> list:
    """Fusionne deux listes de blocs OCR par IoU spatiale (ensemble model).

    Stratégie :
      - Pour chaque bloc du modèle primaire (japan), cherche le meilleur
        correspondant dans le modèle secondaire (ch) par IoU.
      - Si IoU > seuil, compare les confidences et le ratio japonais :
          * texte majoritairement japonais → garde primaire
          * texte alphanumérique → prend le plus confiant des deux
      - Blocs sans correspondance : gardés tels quels (des deux modèles).
    """
    used_secondary = set()
    result = []

    for pb in blocks_primary:
        best_iou  = 0.0
        best_j    = -1
        for j, sb in enumerate(blocks_secondary):
            if j in used_secondary:
                continue
            iou = _box_iou(pb, sb)
            if iou > best_iou:
                best_iou = iou
                best_j   = j

        if best_iou >= iou_thresh and best_j >= 0:
            sb = blocks_secondary[best_j]
            used_secondary.add(best_j)
            jp_ratio = _japanese_ratio(pb['text'])
            if jp_ratio >= 0.3:
                # Texte japonais : le modèle japan est spécialisé → garder
                result.append(pb)
                dbg(f"ensemble: jp={jp_ratio:.2f} → japan «{pb['text'][:30]}»")
            elif sb['confidence'] > pb['confidence'] + 0.05:
                # Code produit ou alphanumérique : ch plus confiant
                dbg(f"ensemble: ch+{sb['confidence']:.2f}>{pb['confidence']:.2f} "
                    f"«{pb['text'][:20]}»→«{sb['text'][:20]}»")
                result.append({**sb, 'left': pb['left'], 'top': pb['top'],
                                'right': pb['right'], 'bottom': pb['bottom']})
            else:
                result.append(pb)
        else:
            result.append(pb)

    # Blocs du modèle secondaire sans correspondance dans le primaire :
    # uniquement ceux qui ne chevauchent pas les blocs déjà acceptés.
    for j, sb in enumerate(blocks_secondary):
        if j in used_secondary:
            continue
        overlaps_existing = any(_box_iou(sb, rb) > 0.15 for rb in result)
        if not overlaps_existing:
            dbg(f"ensemble: bloc ch orphelin ajouté «{sb['text'][:30]}»")
            result.append(sb)
        else:
            dbg(f"ensemble: bloc ch orphelin ignoré (chevauchement) «{sb['text'][:30]}»")

    return result


def run_ocr(image_path, bcp47_lang):
    model_key = LANG_TO_MODEL.get(bcp47_lang, "ch")
    dbg(f"run_ocr : lang={bcp47_lang} → model={model_key}")
    _preprocessed = preprocess_for_rapidocr(image_path)
    img_input = _preprocessed if _preprocessed is not None else image_path

    # ── Modèle primaire (spécialisé langue) ───────────────────────────────────
    ocr_primary = make_ocr(model_key)
    dbg("run_ocr : predict (primary)…")
    result_primary, _ = ocr_primary(img_input)
    dbg("run_ocr : predict OK")
    blocks_primary = result_to_blocks(result_primary)
    dbg(f"run_ocr : {len(blocks_primary)} blocs primaires bruts")

    # ── Ensemble sélectif : modèle ch sur la même image ──────────────────────
    # Activé uniquement si :
    #   1. Le modèle primaire n'est pas déjà ch.
    #   2. La page contient suffisamment de blocs à faible confiance
    #      (moyenne de confiance < 0.78 ou >15 % de blocs sous 0.70).
    # → Skip sur les pages à fort texte japonais propre (économise ~15s).
    if model_key != "ch":
        n_primary = len(blocks_primary)
        low_conf_count = sum(1 for b in blocks_primary if b['confidence'] < 0.70)
        avg_conf = (sum(b['confidence'] for b in blocks_primary) / n_primary
                    if n_primary else 1.0)
        run_ensemble = (avg_conf < 0.78 or
                        (n_primary > 0 and low_conf_count / n_primary > 0.15))
        dbg(f"ensemble trigger : avg_conf={avg_conf:.2f}  "
            f"low_conf={low_conf_count}/{n_primary}  run={run_ensemble}")

        if run_ensemble:
            dbg("run_ocr : predict (ch ensemble)…")
            ocr_ch = make_ocr("ch")
            result_ch, _ = ocr_ch(img_input)
            dbg("run_ocr : predict ch OK")
            blocks_ch = result_to_blocks(result_ch)
            dbg(f"run_ocr : {len(blocks_ch)} blocs ch bruts")
            blocks_raw = _ensemble_blocks(blocks_primary, blocks_ch)
            dbg(f"run_ocr : {len(blocks_raw)} blocs après ensemble")
        else:
            blocks_raw = blocks_primary
    else:
        blocks_raw = blocks_primary

    # Détecte les barrières de tableau (lignes H) pour éviter les fusions inter-lignes.
    # Utilise le tableau numpy du preprocessing (qualité optimale) ou lit l'image source.
    _img_for_barriers = (_preprocessed if isinstance(_preprocessed, np.ndarray)
                         else None)
    row_barriers = _detect_table_row_barriers(_img_for_barriers)

    blocks = layout_analysis(blocks_raw, row_barriers=row_barriers)

    # Déduplication IoU — supprime les blocs qui se chevauchent significativement
    # (DBNet peut détecter la même région à plusieurs échelles).
    blocks = _dedup_by_iou(blocks, iou_thresh=0.25)

    n_before = len(blocks)
    blocks = [b for b in blocks if not _is_garbage_block(b)]
    n_rejected = n_before - len(blocks)
    if n_rejected:
        dbg(f"garbage_filter : {n_before} → {len(blocks)} blocs ({n_rejected} rejetés)")

    # Split des blocs larges contenant plusieurs phrases/valeurs de tableau
    blocks = _split_wide_blocks_at_boundary(blocks)

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
