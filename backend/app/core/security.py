"""JWT-токены — создание и верификация.

Поддерживает два типа токенов:
- Access token (30 дней) — для device_id или user
- Magic token (15 минут) — для верификации email
"""

from datetime import datetime, timedelta, timezone

from jose import JWTError, jwt

from app.core.config import get_settings

settings = get_settings()

ALGORITHM = "HS256"


def create_access_token(subject: str, expires_delta: timedelta | None = None) -> str:
    """Создаёт JWT-токен для переданного subject (device_id или user_id).

    Args:
        subject: Уникальный идентификатор (device_id UUID или "user:<id>")
        expires_delta: Кастомное время жизни токена
    """
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    payload = {
        "sub": subject,
        "exp": expire,
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=ALGORITHM)


def create_magic_token(email: str) -> str:
    """Создаёт короткоживущий JWT для Magic Link (15 минут)."""
    expire = datetime.now(timezone.utc) + timedelta(minutes=15)
    payload = {
        "sub": email,
        "purpose": "magic_link",
        "exp": expire,
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=ALGORITHM)


def decode_access_token(token: str) -> str | None:
    """Декодирует JWT и возвращает subject, или None при невалидном токене."""
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[ALGORITHM])
        return payload.get("sub")
    except JWTError:
        return None


def verify_token(token: str) -> dict | None:
    """Верифицирует JWT и возвращает полный payload. None при ошибке."""
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        return None
