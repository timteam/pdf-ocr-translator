"""
PDF OCR Translator - Backend API
Main FastAPI application
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import logging
from pathlib import Path

# Configure logging
from pythonjsonlogger import jsonlogger

from .routes import router

log_dir = Path("logs")
log_dir.mkdir(exist_ok=True)

logger = logging.getLogger(__name__)
logHandler = logging.FileHandler(log_dir / "app.log")
formatter = jsonlogger.JsonFormatter()
logHandler.setFormatter(formatter)
logger.addHandler(logHandler)
logger.setLevel(logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Application starting up")
    yield
    # Shutdown
    logger.info("Application shutting down")


# Initialize FastAPI app
app = FastAPI(
    title="PDF OCR Translator API",
    description="Open source solution for PDF OCR and translation",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routes
app.include_router(router)


@app.get("/", tags=["root"])
async def root():
    """Root endpoint"""
    return {
        "message": "PDF OCR Translator API",
        "docs": "/docs",
        "version": "0.1.0",
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info",
    )
