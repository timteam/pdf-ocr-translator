#!/usr/bin/env python3
"""
Wrapper PaddleOCR pour pdf-ocr-translator.

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


# Correspondance BCP-47 → code langue PaddleOCR
LANG_MAP = {
    "en": "en",
    "fr": "fr",
    "de": "german",
    "es": "es",
    "it": "it",
    "pt": "pt",
    "nl": "nl",
    "pl": "pl",
    "ru": "ru",
    "ja": "japan",
    "zh": "ch",
    "ko": "korean",
    "ar": "arabic",
    "hi": "hi",
    "th": "th",
    "vi": "vi",
}


def import_paddleocr():
    try:
        from paddleocr import PaddleOCR
        return PaddleOCR
    except ImportError:
        sys.exit(
            "paddleocr non installé.\n"
            "Installer : pip install paddleocr paddlepaddle-cpu"
        )


def make_ocr(lang):
    PaddleOCR = import_paddleocr()
    return PaddleOCR(
        use_angle_cls=True,
        lang=lang,
        show_log=False,
        use_gpu=False,
    )


def extract_items(result):
    """Normalise le résultat PaddleOCR (compatible v2.x et v3.x)."""
    if not result:
        return []
    # v2.x retourne [[items…]], v3.x peut retourner [items…] directement
    first = result[0]
    if first and isinstance(first[0], list) and isinstance(first[0][0], list):
        return first  # v2.x
    if first and isinstance(first[0], (list, tuple)) and len(first[0]) == 2:
        return first  # v3.x déjà aplati
    return result[0] if result else []


def polygon_to_rect(box):
    """Convertit un polygone 4-points en rectangle englobant."""
    xs = [p[0] for p in box]
    ys = [p[1] for p in box]
    return min(xs), min(ys), max(xs), max(ys)


def text_from_result(result, min_conf=0.4):
    """Extrait le texte concaténé d'un résultat PaddleOCR."""
    parts = []
    for item in extract_items(result):
        try:
            box, (text, conf) = item
            if conf >= min_conf and text.strip():
                parts.append(text.strip())
        except (TypeError, ValueError):
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
    """Vrai si le texte ch est trop Latin/vide pour être fiable (page latine)."""
    non_ws = text.replace(" ", "")
    if not non_ws:
        return True
    ascii_alpha = sum(1 for c in non_ws if c.isascii() and c.isalpha())
    return ascii_alpha / len(non_ws) > 0.60


def run_detect(image_path):
    """
    Détection de script en 3 passes au maximum.

    Passe 1 : modèle ch  → fiable pour CJK, coréen, arabe, cyrillique, devanagari, thaï.
              Si le script est clairement non-latin et non-CJK → terminé.
              Si "cjk" → ambiguïté chinois/japonais → passe 2.
              Si latin/vide → possible page japonaise à katakana dominant → passe 2.

    Passe 2 : modèle japan → détecte hiragana/katakana.
              Si "japanese" → terminé.
              Si "cjk" ET passe 1 était déjà "cjk" → chinois → terminé.
              Sinon → passe 3.

    Passe 3 : modèle en  → pages latines uniquement.
    """
    # ── Passe 1 : modèle ch ──────────────────────────────────────────────────
    ocr_ch = make_ocr("ch")
    text_ch = text_from_result(ocr_ch(image_path))
    script_ch = detect_dominant_script(text_ch)

    # Scripts sans ambiguïté → réponse immédiate
    if script_ch in ("arabic", "cyrillic", "devanagari", "thai", "korean", "japanese"):
        json.dump({"text": text_ch, "script": script_ch}, sys.stdout, ensure_ascii=False)
        return

    # ── Passe 2 : modèle japan ───────────────────────────────────────────────
    # Nécessaire si ch voit "cjk" (kanji → chinois ou japonais ?) ou échoue
    # (pages à katakana/hiragana dominants que ch ne reconnaît pas bien).
    if script_ch == "cjk" or is_latin_or_empty(text_ch):
        ocr_jp = make_ocr("japan")
        text_jp = text_from_result(ocr_jp(image_path))
        script_jp = detect_dominant_script(text_jp)

        if script_jp == "japanese":
            json.dump({"text": text_jp, "script": "japanese"}, sys.stdout, ensure_ascii=False)
            return

        if script_ch == "cjk":
            # ch et japan voient du CJK sans hiragana/katakana → chinois
            json.dump({"text": text_ch, "script": "cjk"}, sys.stdout, ensure_ascii=False)
            return

    # ── Passe 3 : modèle en  ─────────────────────────────────────────────────
    ocr_en = make_ocr("en")
    text_en = text_from_result(ocr_en(image_path))
    json.dump({"text": text_en, "script": "latin"}, sys.stdout, ensure_ascii=False)


def run_ocr(image_path, bcp47_lang):
    """OCR complet avec le modèle PaddleOCR adapté à la langue."""
    paddle_lang = LANG_MAP.get(bcp47_lang, "en")
    ocr = make_ocr(paddle_lang)
    result = ocr(image_path)

    blocks = []
    for item in extract_items(result):
        try:
            box, (text, conf) = item
        except (TypeError, ValueError):
            continue
        if conf < 0.5 or not text.strip():
            continue
        left, top, right, bottom = polygon_to_rect(box)
        blocks.append({
            "text": text.strip(),
            "confidence": float(conf),
            "left": float(left),
            "top": float(top),
            "right": float(right),
            "bottom": float(bottom),
        })

    json.dump(blocks, sys.stdout, ensure_ascii=False)


def main():
    if len(sys.argv) < 3:
        sys.exit("Usage: paddleocr.py detect <image> | ocr <image> <bcp47_lang>")

    mode = sys.argv[1]
    image_path = sys.argv[2]

    if not os.path.exists(image_path):
        sys.exit(f"Image introuvable: {image_path}")

    if mode == "detect":
        run_detect(image_path)
    elif mode == "ocr":
        if len(sys.argv) < 4:
            sys.exit("Usage: paddleocr.py ocr <image> <bcp47_lang>")
        run_ocr(image_path, sys.argv[3])
    else:
        sys.exit(f"Mode inconnu: {mode}")


if __name__ == "__main__":
    main()
