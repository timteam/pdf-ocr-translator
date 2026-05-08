"""
Configuration settings
"""

from pydantic_settings import BaseSettings
from pathlib import Path


class Settings(BaseSettings):
    """Application settings"""

    APP_NAME: str = "PDF OCR Translator"
    APP_VERSION: str = "0.1.0"
    DEBUG: bool = False

    # Paths
    OUTPUT_DIR: str = "./output"
    LOGS_DIR: str = "./logs"
    MODELS_DIR: str = "./models"

    # OCR Settings
    OCR_DPI: int = 150
    OCR_LANGUAGES: str = "eng"

    # Translation Settings
    TRANSLATION_DEVICE: int = -1  # -1 for CPU, 0+ for GPU
    TRANSLATION_MAX_LENGTH: int = 512

    # API Settings
    API_HOST: str = "0.0.0.0"
    API_PORT: int = 8000

    # Processing Settings
    MAX_PDF_PAGES: int = 500
    CHUNK_SIZE: int = 32

    class Config:
        env_file = ".env"
        case_sensitive = True


settings = Settings()
