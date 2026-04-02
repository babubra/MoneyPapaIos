"""Auth API — регистрация устройства и выдача JWT-токена.

POST /api/v1/auth/device — принимает device_id (UUID), возвращает Bearer token.
Это единственный endpoint Фазы 1, не требующий авторизации.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import create_access_token
from app.db.models import Device
from app.db.session import get_db
from app.schemas import DeviceAuthRequest, TokenResponse

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/device", response_model=TokenResponse, summary="Регистрация устройства")
async def auth_device(
    body: DeviceAuthRequest,
    db: AsyncSession = Depends(get_db),
) -> TokenResponse:
    """Регистрирует устройство по UUID и выдаёт Bearer-токен.

    Если device_id уже существует — обновляет last_seen_at и выдаёт новый токен.
    Не требует какой-либо авторизации — вызывается при первом запуске iOS-приложения.
    """
    # Ищем существующее устройство
    result = await db.execute(
        select(Device).where(Device.device_id == body.device_id)
    )
    device = result.scalar_one_or_none()

    if device is None:
        # Первый запуск — создаём запись
        device = Device(device_id=body.device_id)
        db.add(device)
        await db.flush()
        logger.info(f"Новое устройство зарегистрировано: {body.device_id}")
    else:
        # Повторный вызов — просто выдаём новый токен (last_seen обновится через onupdate)
        logger.info(f"Обновление токена для устройства: {body.device_id}")

    if device.is_blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Устройство заблокировано",
        )

    # Выдаём токен с subject = device_id
    token = create_access_token(subject=body.device_id)

    return TokenResponse(access_token=token)
