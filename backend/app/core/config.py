"""Настройки приложения — читаются из .env файла."""

import socket
from functools import lru_cache

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


# Защита от placeholder-значений SECRET_KEY (любая строка, начинающаяся с этого префикса, отвергается).
_SECRET_PLACEHOLDER_PREFIX = "change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",  # Игнорировать POSTGRES_* и прочие не-наши переменные
    )

    # ── JWT ──────────────────────────────────────────────────────────
    # SECRET_KEY обязателен и валидируется на минимальную длину + non-placeholder.
    SECRET_KEY: str
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 43200  # 30 дней

    # ── AiTunnel AI (OpenAI-совместимый прокси → Gemini) ────────────
    AITUNNEL_API_KEY: str = ""
    AITUNNEL_BASE_URL: str = "https://api.aitunnel.ru/v1/"
    AI_MODEL: str  # Обязательно задать в .env

    # ── PostgreSQL ──────────────────────────────────────────────────
    DATABASE_URL: str = "postgresql+asyncpg://monpapa:monpapa_dev_secret@localhost:5432/monpapa"

    # ── Rate limiting (legacy, остаются для совместимости — не используются после Auth Model C) ──
    AI_RATE_LIMIT_DAILY: int = 50
    AI_RATE_LIMIT_AUDIO_HOURLY: int = 5
    AI_MAX_TEXT_LENGTH: int = 500
    AI_MAX_AUDIO_SECONDS: int = 30

    # ── Auth Model C ────────────────────────────────────────────────
    # Лимит бесплатных AI-запросов на пользователя (lifetime).
    AI_TRIAL_LIMIT: int = 50
    # Bundle ID для верификации Apple identity_token (audience claim).
    APPLE_BUNDLE_ID: str = "fatau.Monpapa"

    # ── SMTP (Magic Link) ───────────────────────────────────────────
    SMTP_HOST: str = "smtp.yandex.ru"
    SMTP_PORT: int = 465
    SMTP_USER: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM: str = ""

    # ── Авторизация ─────────────────────────────────────────────────
    ALLOWED_EMAILS: str = ""  # Через запятую: "a@b.com,c@d.com"
    # DEV_MODE — автологин без отправки писем; разрешён только на localhost (см. валидатор ниже).
    DEV_MODE: bool = False
    # Опциональный override для случаев, когда DEV_MODE нужен в Docker/CI на не-localhost хосте.
    # Должен быть выставлен явно (`DEV_HOST_OK=true`) — иначе при не-localhost hostname
    # приложение упадёт fail-fast.
    DEV_HOST_OK: bool = False

    # ── CORS ────────────────────────────────────────────────────────
    CORS_ORIGINS: str = "http://localhost:3000,http://localhost:8080"

    # ── Validators ──────────────────────────────────────────────────

    @field_validator("SECRET_KEY")
    @classmethod
    def _reject_default_secret(cls, v: str) -> str:
        """Запрещаем placeholder-значения и слишком короткие ключи.

        Эта проверка — fail-fast: backend не поднимется, если SECRET_KEY не задан корректно.
        Сгенерировать ключ: ``openssl rand -hex 32``.
        """
        if not v:
            raise ValueError("SECRET_KEY is required (set in .env). Generate with: openssl rand -hex 32")
        if v.startswith(_SECRET_PLACEHOLDER_PREFIX):
            raise ValueError(
                "SECRET_KEY is set to a placeholder value. "
                "Generate a real one: openssl rand -hex 32"
            )
        if len(v) < 32:
            raise ValueError(f"SECRET_KEY must be at least 32 characters (got {len(v)}).")
        return v

    @model_validator(mode="after")
    def _enforce_dev_mode_localhost(self) -> "Settings":
        """DEV_MODE разрешён только на localhost-хостах либо при явном DEV_HOST_OK=true.

        Это защищает от случайного запуска прод-инстанса с DEV_MODE=true (auto-login без писем).
        В Docker hostname обычно — random container ID, поэтому в контейнере нужно либо
        ставить DEV_MODE=false, либо явно DEV_HOST_OK=true.
        """
        if not self.DEV_MODE:
            return self
        if self.DEV_HOST_OK:
            return self
        hostname = socket.gethostname().lower()
        if hostname.startswith(("localhost", "127.")) or hostname == "127.0.0.1":
            return self
        raise ValueError(
            f"DEV_MODE=true on non-localhost host (hostname={hostname}). "
            "Set DEV_HOST_OK=true if this is intentional, or DEV_MODE=false in production."
        )

    # ── Helpers ─────────────────────────────────────────────────────

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
