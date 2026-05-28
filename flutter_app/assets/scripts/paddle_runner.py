#!/usr/bin/env python3
"""
Wrapper PaddleOCR 3.x pour pdf-ocr-translator.

Modes :
  detect <image_path>
      Extrait du texte brut depuis l'image (pour identification de langue par FastText).
      stdout → JSON  {"text": "…", "script": "latin|cjk|japanese|korean|arabic|cyrillic|devanagari|thai"}

  ocr <image_path> <bcp47_lang>
      OCR complet avec le modèle adapté à la langue.
      stdout → JSON  [{"text":"…", "confidence":0.95, "left":10, "top":5, "right":200, "bottom":30}, …]
"""
import sys
import os
import json
import logging

# Supprimer les messages de log verbeux au démarrage
for _n in ("paddle", "paddleocr", "paddlex", "ppdet", "root"):
    logging.getLogger(_n).setLevel(logging.ERROR)


# Correspondance BCP-47 → code langue PaddleOCR 3.x
LANG_MAP = {
    "en": "en",
    "fr": "fr",
    "de": "de",
    "es": "es",
    "it": "it",
    "pt": "pt",
    "nl": "nl",
    "pl": "pl",
    "ru": "ru",
    "ja": "japan",
    "zh": "ch",
    "ko": "korean",
    "ar": "ar",       # ARABIC_LANGS en 3.x (était "arabic" en 2.x)
    "hi": "hi",
    "th": "th",
    "vi": "vi",
}


def import_paddleocr():
    try:
        from paddleocr import PaddleOCR
        return PaddleOCR
    except Exception as e:
        sys.exit(f"paddleocr import failed: {e}")


def make_ocr(lang):
    PaddleOCR = import_paddleocr()
    return PaddleOCR(
        lang=lang,
        use_textline_orientation=True,   # détection de l'orientation des lignes
        text_det_unclip_ratio=1.6,       # boîtes légèrement plus larges → moins de coupures
        text_recognition_batch_size=6,   # reconnaissance en parallèle
    )


def polygon_to_rect(poly):
    """Convertit un polygone 4-points en rectangle englobant."""
    xs = [float(p[0]) for p in poly]
    ys = [float(p[1]) for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


def text_from_result(result_list, min_conf=0.4):
    """Extrait le texte concaténé d'un résultat PaddleOCR 3.x."""
    parts = []
    for result in result_list:
        try:
            for text, conf in zip(result["rec_texts"], result["rec_scores"]):
                if float(conf) >= min_conf and text.strip():
                    parts.append(text.strip())
        except (KeyError, TypeError):
            pass
    return " ".join(parts)


def detect_dominant_script(text):
    """Analyse Unicode pour identifier le script dominant."""
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
    """Vrai si le texte est trop Latin/vide pour être fiable (page latine)."""
    non_ws = text.replace(" ", "")
    if not non_ws:
        return True
    ascii_alpha = sum(1 for c in non_ws if c.isascii() and c.isalpha())
    return ascii_alpha / len(non_ws) > 0.60


def run_detect(image_path):
    """
    Détection de script en 3 passes au maximum.

    Passe 1 : modèle ch  → fiable pour CJK, coréen, arabe, cyrillique, devanagari, thaï.
    Passe 2 : modèle japan → détecte hiragana/katakana.
    Passe 3 : modèle en  → pages latines uniquement.
    """
    # ── Passe 1 : modèle ch ──────────────────────────────────────────────────
    ocr_ch = make_ocr("ch")
    text_ch = text_from_result(ocr_ch.predict(image_path))
    script_ch = detect_dominant_script(text_ch)

    if script_ch in ("arabic", "cyrillic", "devanagari", "thai", "korean", "japanese"):
        json.dump({"text": text_ch, "script": script_ch}, sys.stdout, ensure_ascii=False)
        return

    # ── Passe 2 : modèle japan ───────────────────────────────────────────────
    if script_ch == "cjk" or is_latin_or_empty(text_ch):
        ocr_jp = make_ocr("japan")
        text_jp = text_from_result(ocr_jp.predict(image_path))
        script_jp = detect_dominant_script(text_jp)

        if script_jp == "japanese":
            json.dump({"text": text_jp, "script": "japanese"}, sys.stdout, ensure_ascii=False)
            return

        if script_ch == "cjk":
            json.dump({"text": text_ch, "script": "cjk"}, sys.stdout, ensure_ascii=False)
            return

    # ── Passe 3 : modèle en  ─────────────────────────────────────────────────
    ocr_en = make_ocr("en")
    text_en = text_from_result(ocr_en.predict(image_path))
    json.dump({"text": text_en, "script": "latin"}, sys.stdout, ensure_ascii=False)


def run_ocr(image_path, bcp47_lang):
    """OCR complet avec le modèle PaddleOCR 3.x adapté à la langue."""
    paddle_lang = LANG_MAP.get(bcp47_lang, "en")
    ocr = make_ocr(paddle_lang)
    result_list = ocr.predict(image_path)

    blocks = []
    for result in result_list:
        try:
            polys = result["rec_polys"]
            texts = result["rec_texts"]
            scores = result["rec_scores"]
        except (KeyError, TypeError):
            continue
        for poly, text, conf in zip(polys, texts, scores):
            if float(conf) < 0.5 or not text.strip():
                continue
            left, top, right, bottom = polygon_to_rect(poly)
            blocks.append({
                "text": text.strip(),
                "confidence": float(conf),
                "left": left,
                "top": top,
                "right": right,
                "bottom": bottom,
            })

    json.dump(blocks, sys.stdout, ensure_ascii=False)


def main():
    if len(sys.argv) < 3:
        sys.exit("Usage: paddle_runner.py detect <image> | ocr <image> <bcp47_lang>")

    mode = sys.argv[1]
    image_path = sys.argv[2]

    if not os.path.exists(image_path):
        sys.exit(f"Image introuvable: {image_path}")

    if mode == "detect":
        run_detect(image_path)
    elif mode == "ocr":
        if len(sys.argv) < 4:
            sys.exit("Usage: paddle_runner.py ocr <image> <bcp47_lang>")
        run_ocr(image_path, sys.argv[3])
    else:
        sys.exit(f"Mode inconnu: {mode}")


if __name__ == "__main__":
    main()
