"""
API routes for PDF processing
"""

from fastapi import APIRouter, UploadFile, File, HTTPException
from fastapi.responses import StreamingResponse
import logging
import shutil
from pathlib import Path
import json

from .models import (
    TranslateRequest,
    TranslateResponse,
    OCRRequest,
    OCRResponse,
    PDFProcessRequest,
    HealthResponse,
    LanguageEnum,
)
from .ocr import TesseractOCR
from .translation import TextTranslator
from .pdf_processor import PDFProcessor
from .service import PDFTranslationService

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1", tags=["api"])

# Initialize services
ocr_service = TesseractOCR()
translator_service = TextTranslator()
pdf_service = PDFTranslationService()


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return {
        "status": "ok",
        "version": "0.1.0",
        "available_languages": list(LanguageEnum.__members__.values()),
    }


@router.get("/languages")
async def get_supported_languages():
    """Get list of supported languages"""
    return {"languages": [lang.value for lang in LanguageEnum]}


@router.post("/translate", response_model=TranslateResponse)
async def translate_text(request: TranslateRequest):
    """Translate text"""
    try:
        result = translator_service.translate_text(
            request.text,
            request.source_language.value,
            request.target_language.value,
        )

        if not result["success"]:
            raise HTTPException(status_code=400, detail=result.get("error"))

        return TranslateResponse(
            original=result["original"],
            translated=result["translated"],
            source_language=result["source_language"],
            target_language=result["target_language"],
            success=True,
        )
    except Exception as e:
        logger.error(f"Translation error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/ocr", response_model=OCRResponse)
async def ocr_image(request: OCRRequest):
    """Extract text from image using OCR"""
    try:
        result = ocr_service.extract_text(request.image_url)

        if not result["success"]:
            return OCRResponse(
                success=False,
                text="",
                confidence=0.0,
                error=result.get("error"),
            )

        text_blocks = ocr_service.extract_text_with_positions(
            request.image_url, request.language.value
        )

        return OCRResponse(
            success=True,
            text=result["text"],
            confidence=result["confidence"],
            blocks=text_blocks,
        )
    except Exception as e:
        logger.error(f"OCR error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/process-pdf")
async def process_pdf(
    pdf_file: UploadFile = File(...),
    source_language: str = "en",
    target_language: str = "fr",
):
    """
    Process PDF with OCR and translation
    Returns Server-Sent Events stream with progress
    """
    try:
        # Save uploaded file
        temp_path = Path(f"./temp/{pdf_file.filename}")
        temp_path.parent.mkdir(parents=True, exist_ok=True)

        with open(temp_path, "wb") as buffer:
            shutil.copyfileobj(pdf_file.file, buffer)

        # Create output path
        output_path = Path("./output") / f"translated_{pdf_file.filename}"

        async def generate():
            """Stream progress events"""
            async for progress in pdf_service.process_pdf(
                str(temp_path),
                source_language,
                target_language,
                str(output_path),
            ):
                yield f"data: {json.dumps(progress)}\n\n"

            # Cleanup temp file
            temp_path.unlink(missing_ok=True)

        return StreamingResponse(generate(), media_type="text/event-stream")

    except Exception as e:
        logger.error(f"PDF processing error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/download/{filename}")
async def download_file(filename: str):
    """Download processed PDF"""
    try:
        file_path = Path("./output") / filename
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")

        return StreamingResponse(
            open(file_path, "rb"),
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename={filename}"},
        )
    except Exception as e:
        logger.error(f"Download error: {e}")
        raise HTTPException(status_code=500, detail=str(e))
