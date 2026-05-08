"""
Pydantic models for API requests/responses
"""

from pydantic import BaseModel, Field
from typing import List, Optional, Dict
from enum import Enum


class LanguageEnum(str, Enum):
    """Supported languages"""

    EN = "en"
    FR = "fr"
    ES = "es"
    DE = "de"
    IT = "it"
    PT = "pt"
    NL = "nl"
    PL = "pl"
    RU = "ru"
    JA = "ja"
    ZH = "zh"
    KO = "ko"
    AR = "ar"
    HI = "hi"
    TH = "th"
    VI = "vi"


class TranslateRequest(BaseModel):
    """Request model for translation"""

    text: str = Field(..., min_length=1, max_length=10000)
    source_language: LanguageEnum
    target_language: LanguageEnum


class TranslateResponse(BaseModel):
    """Response model for translation"""

    original: str
    translated: str
    source_language: str
    target_language: str
    success: bool


class TextBlock(BaseModel):
    """Text block with position information"""

    text: str
    x: int
    y: int
    width: int
    height: int
    confidence: int


class OCRRequest(BaseModel):
    """Request model for OCR"""

    image_url: str = Field(..., description="URL or path to image")
    language: LanguageEnum = Field(default=LanguageEnum.EN)


class OCRResponse(BaseModel):
    """Response model for OCR"""

    success: bool
    text: str
    confidence: float
    blocks: Optional[List[TextBlock]] = None
    error: Optional[str] = None


class PDFProcessRequest(BaseModel):
    """Request model for PDF processing"""

    pdf_url: str = Field(..., description="URL or path to PDF file")
    source_language: LanguageEnum
    target_language: LanguageEnum
    output_path: str = Field(default="./output/translated.pdf")


class ProgressUpdate(BaseModel):
    """Progress update for PDF processing"""

    page: int
    total_pages: int
    status: str
    current_step: str
    error: Optional[str] = None


class HealthResponse(BaseModel):
    """Health check response"""

    status: str
    version: str
    available_languages: List[str]
