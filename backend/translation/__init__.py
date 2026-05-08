"""
Translation Module - Hugging Face Transformers integration
"""

from transformers import pipeline
from typing import List, Dict
import logging

logger = logging.getLogger(__name__)


class TextTranslator:
    """Translation using Hugging Face transformers"""

    # Supported language pairs
    SUPPORTED_LANGUAGES = {
        "fr": "French",
        "es": "Spanish",
        "de": "German",
        "it": "Italian",
        "pt": "Portuguese",
        "nl": "Dutch",
        "pl": "Polish",
        "ru": "Russian",
        "ja": "Japanese",
        "zh": "Chinese",
        "ko": "Korean",
        "ar": "Arabic",
        "hi": "Hindi",
        "th": "Thai",
        "vi": "Vietnamese",
    }

    def __init__(self):
        """Initialize translation pipeline"""
        self.pipelines = {}

    def _get_pipeline(self, src_lang: str, tgt_lang: str) -> pipeline:
        """Get or create translation pipeline"""
        key = f"{src_lang}-{tgt_lang}"
        if key not in self.pipelines:
            try:
                logger.info(f"Loading translation model: {src_lang} -> {tgt_lang}")
                self.pipelines[key] = pipeline(
                    "translation",
                    model=f"Helsinki-NLP/opus-mt-{src_lang}-{tgt_lang}",
                    device=-1,  # CPU; use 0 for GPU
                )
            except Exception as e:
                logger.error(f"Failed to load translation model: {e}")
                raise

        return self.pipelines[key]

    def translate_text(
        self, text: str, source_lang: str, target_lang: str
    ) -> Dict:
        """
        Translate text from source to target language

        Args:
            text: Text to translate
            source_lang: Source language code (e.g., 'en')
            target_lang: Target language code (e.g., 'fr')

        Returns:
            Dictionary with translated text and metadata
        """
        if not text or not text.strip():
            return {"success": True, "translated": "", "original": text}

        try:
            translator = self._get_pipeline(source_lang, target_lang)
            result = translator(text, max_length=512)
            translated_text = result[0]["translation_text"]

            return {
                "success": True,
                "original": text,
                "translated": translated_text,
                "source_lang": source_lang,
                "target_lang": target_lang,
            }
        except Exception as e:
            logger.error(f"Translation error: {e}")
            return {
                "success": False,
                "original": text,
                "error": str(e),
            }

    def translate_batch(
        self, texts: List[str], source_lang: str, target_lang: str
    ) -> List[Dict]:
        """Translate a batch of texts"""
        return [
            self.translate_text(text, source_lang, target_lang) for text in texts
        ]

    @classmethod
    def list_supported_languages(cls) -> Dict:
        """List all supported languages"""
        return cls.SUPPORTED_LANGUAGES
