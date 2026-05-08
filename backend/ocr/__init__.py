"""
OCR Module - Tesseract integration
"""

import pytesseract
from PIL import Image
from pathlib import Path
from typing import Tuple, List, Dict
import logging

logger = logging.getLogger(__name__)


class TesseractOCR:
    """Tesseract-based OCR processor"""

    def __init__(self, languages: str = "eng"):
        """
        Initialize OCR processor

        Args:
            languages: Tesseract language codes (e.g., 'eng', 'fra', 'spa')
        """
        self.languages = languages

    def extract_text(self, image_path: str) -> Dict:
        """
        Extract text from image

        Args:
            image_path: Path to image file

        Returns:
            Dictionary with extracted text and metadata
        """
        try:
            image = Image.open(image_path)
            text = pytesseract.image_to_string(image, lang=self.languages)

            # Get detailed data for positioning
            data = pytesseract.image_to_data(
                image, lang=self.languages, output_type=pytesseract.Output.DICT
            )

            return {
                "success": True,
                "text": text,
                "data": data,
                "confidence": self._calculate_confidence(data),
            }
        except Exception as e:
            logger.error(f"OCR extraction error: {e}")
            return {"success": False, "error": str(e)}

    @staticmethod
    def _calculate_confidence(data: Dict) -> float:
        """Calculate average confidence from OCR data"""
        confidences = [
            int(conf) for conf in data.get("conf", []) if int(conf) > 0
        ]
        if not confidences:
            return 0.0
        return sum(confidences) / len(confidences)

    def extract_text_with_positions(self, image_path: str) -> List[Dict]:
        """
        Extract text blocks with their positions

        Returns:
            List of text blocks with x, y, width, height, text, confidence
        """
        try:
            image = Image.open(image_path)
            data = pytesseract.image_to_data(
                image, lang=self.languages, output_type=pytesseract.Output.DICT
            )

            text_blocks = []
            for i in range(len(data["text"])):
                if int(data["conf"][i]) > 0:
                    text_blocks.append(
                        {
                            "text": data["text"][i],
                            "x": data["left"][i],
                            "y": data["top"][i],
                            "width": data["width"][i],
                            "height": data["height"][i],
                            "confidence": int(data["conf"][i]),
                        }
                    )

            return text_blocks
        except Exception as e:
            logger.error(f"OCR positioning error: {e}")
            return []
