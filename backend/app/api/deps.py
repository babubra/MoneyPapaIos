"""FastAPI dependencies — аутентификация и авторизация.

Двухуровневая система:
1. get_current_device — всегда доступен (анонимный device_id)
2. get_current_user — доступен если device привязан к User
3. require_user — 401 если не авторизован

В DEV_MODE без токена — автологин через dev-пользователя.
"""

import logging

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.security import decode_access_token
from app.db.models import Device, User
from app.db.session import get_db

logger = logging.getLogger(__name__)
settings = get_settings()

# auto_error=False — не бросаем 403 автоматически, обрабатываем сами
security = HTTPBearer(auto_error=False)


async def get_current_device(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    db: AsyncSession = Depends(get_db),
) -> Device:
    """Извлекает текущее устройство из JWT.

    JWT subject содержит device_id (UUID).
    В DEV_MODE без токена — создаёт/возвращает dev-устройство.
    """
    # DEV_MODE: автологин без токена
    if settings.DEV_MODE and credentials is None:
        dev_device_id = "00000000-0000-0000-0000-000000000000"
        result = await db.execute(
            select(Device).where(Device.device_id == dev_device_id)
        )
        device = result.scalar_one_or_none()
        if not device:
            device = Device(device_id=dev_device_id)
            db.add(device)
            await db.flush()
            logger.info("DEV_MODE: создано dev-устройство")
        return device

    # Обычный режим: требуем токен
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация",
        )

    subject = decode_access_token(credentials.credentials)
    if subject is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Невалидный или просроченный токен",
        )

    # Ищем устройство по device_id из токена
    result = await db.execute(
        select(Device).where(Device.device_id == subject)
    )
    device = result.scalar_one_or_none()

    if device is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Устройство не найдено",
        )

    if device.is_blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Устройство заблокировано",
        )

    return device


async def get_current_user(
    device: Device = Depends(get_current_device),
    db: AsyncSession = Depends(get_db),
) -> User | None:
    """Возвращает User, если device привязан к аккаунту. None если анонимный.

    В DEV_MODE — автоматически создаёт dev-пользователя.
    """
    # DEV_MODE: автологин
    if settings.DEV_MODE and device.user_id is None:
        dev_email = settings.allowed_emails_list[0] if settings.allowed_emails_list else "dev@monpapa.local"
        result = await db.execute(select(User).where(User.email == dev_email))
        user = result.scalar_one_or_none()
        if not user:
            user = User(email=dev_email, display_name="Developer")
            db.add(user)
            await db.flush()
            device.user_id = user.id
            await db.flush()
            logger.info(f"DEV_MODE: создан dev-пользователь {dev_email}")
        elif device.user_id is None:
            device.user_id = user.id
            await db.flush()
        return user

    if device.user_id is None:
        return None

    result = await db.execute(select(User).where(User.id == device.user_id))
    return result.scalar_one_or_none()


async def require_user(
    user: User | None = Depends(get_current_user),
) -> User:
    """Требует авторизованного пользователя. 401 если анонимный."""
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация. Войдите через Magic Link или Sign in with Apple.",
        )
    return user
