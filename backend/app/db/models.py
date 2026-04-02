"""SQLAlchemy ORM-модели для Фазы 1 MonPapa.

Только модели, необходимые для deviceId-авторизации и rate limiting.
Фаза 2 добавит User, Category, Transaction и т.д.
"""

from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Integer, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Device(Base):
    """Устройство пользователя — основная единица идентификации в Фазе 1.

    Каждый UUID из iOS Keychain создаёт одну запись Device.
    В Фазе 2 будет привязан к User через user_id.
    """

    __tablename__ = "devices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    device_id: Mapped[str] = mapped_column(String(36), unique=True, index=True, nullable=False)

    # Rate limiting — текстовые запросы (сброс ежедневно)
    ai_requests_today: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ai_requests_date: Mapped[str | None] = mapped_column(String(10), nullable=True)  # YYYY-MM-DD

    # Rate limiting — аудио-запросы (сброс каждый час)
    ai_audio_requests_hour: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ai_audio_hour: Mapped[str | None] = mapped_column(String(13), nullable=True)  # YYYY-MM-DDTHH

    # Флаг блокировки (на случай злоупотреблений)
    is_blocked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Метаданные
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    def __repr__(self) -> str:
        return f"<Device id={self.id} device_id={self.device_id!r}>"
