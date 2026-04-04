"""Настройки приложения — читаются из .env файла."""

from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
    )

    # JWT
    SECRET_KEY: str = "change-me-to-a-long-random-string-at-least-32-chars"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 43200  # 30 дней

    # AiTunnel AI (OpenAI-совместимый прокси → Gemini)
    AITUNNEL_API_KEY: str = ""
    AITUNNEL_BASE_URL: str = "https://api.aitunnel.ru/v1/"
    AI_MODEL: str  # Обязательно задать в .env

    # База данных
    DATABASE_URL: str = "sqlite+aiosqlite:///./monpapa.db"

    # Rate limiting
    AI_RATE_LIMIT_DAILY: int = 50         # запросов текста в день на deviceId
    AI_RATE_LIMIT_AUDIO_HOURLY: int = 5   # аудио-запросов в час на deviceId
    AI_MAX_TEXT_LENGTH: int = 500         # макс. символов в текстовом запросе
    AI_MAX_AUDIO_SECONDS: int = 30        # макс. секунд активной речи

    # CORS
    CORS_ORIGINS: str = "http://localhost:3000,http://localhost:8080"

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    """Возвращает кешированный экземпляр настроек."""
    return Settings()
