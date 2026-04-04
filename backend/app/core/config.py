"""Настройки приложения — читаются из .env файла."""

from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",  # Игнорировать POSTGRES_* и прочие не-наши переменные
    )

    # JWT
    SECRET_KEY: str = "change-me-to-a-long-random-string-at-least-32-chars"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 43200  # 30 дней

    # AiTunnel AI (OpenAI-совместимый прокси → Gemini)
    AITUNNEL_API_KEY: str = ""
    AITUNNEL_BASE_URL: str = "https://api.aitunnel.ru/v1/"
    AI_MODEL: str  # Обязательно задать в .env

    # PostgreSQL
    DATABASE_URL: str = "postgresql+asyncpg://monpapa:monpapa_dev_secret@localhost:5432/monpapa"

    # Rate limiting
    AI_RATE_LIMIT_DAILY: int = 50         # запросов текста в день на deviceId
    AI_RATE_LIMIT_AUDIO_HOURLY: int = 5   # аудио-запросов в час на deviceId
    AI_MAX_TEXT_LENGTH: int = 500         # макс. символов в текстовом запросе
    AI_MAX_AUDIO_SECONDS: int = 30        # макс. секунд активной речи

    # SMTP (Magic Link)
    SMTP_HOST: str = "smtp.yandex.ru"
    SMTP_PORT: int = 465
    SMTP_USER: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM: str = ""

    # Авторизация
    ALLOWED_EMAILS: str = ""  # Через запятую: "a@b.com,c@d.com"
    DEV_MODE: bool = False

    # CORS
    CORS_ORIGINS: str = "http://localhost:3000,http://localhost:8080"

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]

    @property
    def allowed_emails_list(self) -> list[str]:
        """Список разрешённых email (пусто = все разрешены)."""
        return [e.strip().lower() for e in self.ALLOWED_EMAILS.split(",") if e.strip()]


@lru_cache
def get_settings() -> Settings:
    """Возвращает кешированный экземпляр настроек."""
    return Settings()
