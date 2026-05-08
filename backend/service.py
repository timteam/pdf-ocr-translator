"""
PDF Processing Service - Orchestrates OCR and translation
"""

import asyncio
import logging
from pathlib import Path
from typing import AsyncGenerator, Dict, Optional
import json
from datetime import datetime

from .ocr import TesseractOCR
from .translation import TextTranslator
from .pdf_processor import PDFProcessor
from .models import ProgressUpdate

logger = logging.getLogger(__name__)


class PDFTranslationService:
    """Service for translating PDFs"""

    def __init__(self):
        """Initialize service"""
        self.ocr = TesseractOCR()
        self.translator = TextTranslator()
        self.pdf_processor = PDFProcessor()

    async def process_pdf(
        self,
        pdf_path: str,
        source_lang: str,
        target_lang: str,
        output_path: str,
    ) -> AsyncGenerator[Dict, None]:
        """
        Process PDF with progress updates

        Args:
            pdf_path: Path to input PDF
            source_lang: Source language code
            target_lang: Target language code
            output_path: Path to save translated PDF

        Yields:
            Progress updates
        """
        try:
            # Get PDF info
            pdf_info = self.pdf_processor.get_pdf_info(pdf_path)
            num_pages = pdf_info.get("num_pages", 0)

            if num_pages == 0:
                yield {
                    "success": False,
                    "error": "Could not read PDF",
                }
                return

            logger.info(f"Processing PDF: {num_pages} pages")
            yield {
                "page": 0,
                "total_pages": num_pages,
                "status": "initialized",
                "current_step": "Converting PDF to images",
            }

            # Convert PDF to images
            images = self.pdf_processor.pdf_to_images(pdf_path)

            # Process each page
            translated_images = []

            for page_idx, image in enumerate(images):
                # Extract text with positions
                logger.info(f"Processing page {page_idx + 1}/{num_pages}")

                yield {
                    "page": page_idx + 1,
                    "total_pages": num_pages,
                    "status": "processing",
                    "current_step": "OCR extraction",
                }

                text_blocks = self.ocr.extract_text_with_positions(
                    image, source_lang
                )

                yield {
                    "page": page_idx + 1,
                    "total_pages": num_pages,
                    "status": "processing",
                    "current_step": "Text translation",
                }

                # Translate each block
                for block in text_blocks:
                    result = self.translator.translate_text(
                        block["text"], source_lang, target_lang
                    )
                    if result["success"]:
                        block["translated"] = result["translated"]
                    else:
                        block["translated"] = block["text"]

                # Overlay translated text on image
                yield {
                    "page": page_idx + 1,
                    "total_pages": num_pages,
                    "status": "processing",
                    "current_step": "Generating overlay",
                }

                translated_image = self.pdf_processor.overlay_text_on_image(
                    image, text_blocks
                )
                translated_images.append(translated_image)

                # Log processing details
                self._log_page_processing(
                    page_idx + 1, text_blocks, source_lang, target_lang
                )

            # Create output PDF
            yield {
                "page": num_pages,
                "total_pages": num_pages,
                "status": "finalizing",
                "current_step": "Creating PDF",
            }

            output_dir = Path(output_path).parent
            output_dir.mkdir(parents=True, exist_ok=True)

            self.pdf_processor.create_pdf_from_images(translated_images, output_path)

            logger.info(f"PDF created: {output_path}")

            yield {
                "page": num_pages,
                "total_pages": num_pages,
                "status": "completed",
                "current_step": "Done",
                "output_path": output_path,
            }

        except Exception as e:
            logger.error(f"PDF processing error: {e}")
            yield {
                "success": False,
                "status": "error",
                "error": str(e),
            }

    @staticmethod
    def _log_page_processing(
        page_num: int,
        text_blocks: list,
        source_lang: str,
        target_lang: str,
    ):
        """Log page processing details"""
        log_data = {
            "timestamp": datetime.now().isoformat(),
            "page": page_num,
            "blocks": len(text_blocks),
            "source_language": source_lang,
            "target_language": target_lang,
            "blocks_detail": [
                {
                    "text": block.get("text"),
                    "translated": block.get("translated"),
                    "confidence": block.get("confidence"),
                    "position": {
                        "x": block.get("x"),
                        "y": block.get("y"),
                        "width": block.get("width"),
                        "height": block.get("height"),
                    },
                }
                for block in text_blocks
            ],
        }

        log_file = Path("logs") / f"page_{page_num:04d}.json"
        log_file.parent.mkdir(parents=True, exist_ok=True)

        with open(log_file, "w") as f:
            json.dump(log_data, f, indent=2, ensure_ascii=False)
