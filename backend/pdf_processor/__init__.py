"""
PDF Processor Module - PDF manipulation and image extraction
"""

from pdf2image import convert_from_path
from pypdf import PdfReader, PdfWriter
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
from typing import List, Dict, Tuple
import logging
import io

logger = logging.getLogger(__name__)


class PDFProcessor:
    """PDF processing and manipulation"""

    @staticmethod
    def pdf_to_images(pdf_path: str, dpi: int = 150) -> List[Image.Image]:
        """
        Convert PDF pages to images

        Args:
            pdf_path: Path to PDF file
            dpi: Resolution in dots per inch

        Returns:
            List of PIL Image objects
        """
        try:
            images = convert_from_path(pdf_path, dpi=dpi)
            logger.info(f"Converted {len(images)} pages from PDF")
            return images
        except Exception as e:
            logger.error(f"PDF to images conversion failed: {e}")
            raise

    @staticmethod
    def overlay_text_on_image(
        image: Image.Image,
        text_blocks: List[Dict],
        font_size: int = 12,
        bg_opacity: int = 200,
    ) -> Image.Image:
        """
        Overlay translated text on image

        Args:
            image: PIL Image object
            text_blocks: List of text blocks with positions
            font_size: Font size for text
            bg_opacity: Background opacity (0-255)

        Returns:
            Modified PIL Image
        """
        image_copy = image.copy()
        draw = ImageDraw.Draw(image_copy, "RGBA")

        # Use default font (PIL doesn't have reliable TTF loading)
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", font_size)
        except:
            font = ImageFont.load_default()

        for block in text_blocks:
            x, y = block["x"], block["y"]
            width, height = block["width"], block["height"]
            text = block.get("translated", block.get("text", ""))

            # Draw semi-transparent background
            draw.rectangle(
                [x, y, x + width, y + height],
                fill=(255, 255, 255, bg_opacity),
            )

            # Draw text
            draw.text((x, y), text, font=font, fill=(0, 0, 0, 255))

        return image_copy

    @staticmethod
    def create_pdf_from_images(images: List[Image.Image], output_path: str):
        """
        Create PDF from list of images

        Args:
            images: List of PIL Image objects
            output_path: Path to output PDF
        """
        try:
            # Convert RGBA to RGB if needed
            rgb_images = []
            for img in images:
                if img.mode == "RGBA":
                    rgb_img = Image.new("RGB", img.size, (255, 255, 255))
                    rgb_img.paste(img, mask=img.split()[3])
                    rgb_images.append(rgb_img)
                else:
                    rgb_images.append(img.convert("RGB"))

            rgb_images[0].save(output_path, save_all=True, append_images=rgb_images[1:])
            logger.info(f"PDF created: {output_path}")
        except Exception as e:
            logger.error(f"PDF creation failed: {e}")
            raise

    @staticmethod
    def get_pdf_info(pdf_path: str) -> Dict:
        """Get PDF metadata"""
        try:
            reader = PdfReader(pdf_path)
            return {
                "num_pages": len(reader.pages),
                "is_encrypted": reader.is_encrypted,
                "metadata": reader.metadata,
            }
        except Exception as e:
            logger.error(f"Failed to read PDF info: {e}")
            return {}
