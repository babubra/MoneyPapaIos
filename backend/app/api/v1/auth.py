"""Auth API — регистрация устройства + Magic Link авторизация.

Эндпоинты:
- POST /api/v1/auth/device       — анонимная регистрация (device_id → JWT)
- POST /api/v1/auth/request-link — запрос Magic Link + PIN на email
- POST /api/v1/auth/verify-pin   — верификация PIN → JWT
- GET  /api/v1/auth/verify       — верификация Magic Link (редирект)
- GET  /api/v1/auth/me           — текущий пользователь
- POST /api/v1/auth/link-device  — привязка device к аккаунту
"""

import logging
import random
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_device, get_current_user, require_user
from app.core.config import get_settings
from app.core.email import send_magic_link
from app.core.security import create_access_token, create_magic_token, verify_token
from app.db.models import Device, MagicCode, User, UserSettings
from app.db.session import get_db

logger = logging.getLogger(__name__)
router = APIRouter()
settings = get_settings()


# ── Pydantic-схемы (локальные для auth) ──────────────────────────

class DeviceAuthRequest(BaseModel):
    """Запрос регистрации/обновления устройства."""
    device_id: str = Field(..., min_length=36, max_length=36, description="UUID устройства из iOS Keychain")


class TokenResponse(BaseModel):
    """Ответ с Bearer-токеном."""
    access_token: str
    token_type: str = "bearer"


class MagicLinkRequest(BaseModel):
    """Запрос на отправку Magic Link."""
    email: str = Field(..., min_length=3)


class PinVerifyRequest(BaseModel):
    """Верификация по PIN-коду."""
    email: str = Field(..., min_length=3)
    code: str = Field(..., min_length=6, max_length=6)
    device_id: str = Field(..., min_length=36, max_length=36)


class LinkDeviceRequest(BaseModel):
    """Привязка устройства к аккаунту."""
    device_id: str = Field(..., min_length=36, max_length=36)


class UserResponse(BaseModel):
    """Информация о текущем пользователе."""
    id: int
    email: str | None
    display_name: str | None
    apple_user_id: str | None = None
    created_at: datetime

    model_config = {"from_attributes": True}


# ── Вспомогательные функции ──────────────────────────────────────

def _generate_pin() -> str:
    """Генерирует 6-значный PIN-код."""
    return f"{random.randint(100000, 999999)}"


async def _get_or_create_user(db: AsyncSession, email: str) -> User:
    """Получает или создаёт пользователя по email."""
    result = await db.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user:
        user = User(email=email)
        db.add(user)
        await db.flush()
        # Создаём настройки по умолчанию
        db.add(UserSettings(user_id=user.id))
        await db.flush()
        logger.info(f"Новый пользователь создан: {email}")
    return user


# ── Эндпоинты ────────────────────────────────────────────────────

@router.post("/device", response_model=TokenResponse, summary="Регистрация устройства")
async def auth_device(
    body: DeviceAuthRequest,
    db: AsyncSession = Depends(get_db),
) -> TokenResponse:
    """Регистрирует устройство по UUID и выдаёт Bearer-токен.

    Если device_id уже существует — обновляет last_seen_at и выдаёт новый токен.
    Не требует какой-либо авторизации — вызывается при первом запуске iOS-приложения.
    """
    result = await db.execute(
        select(Device).where(Device.device_id == body.device_id)
    )
    device = result.scalar_one_or_none()

    if device is None:
        device = Device(device_id=body.device_id)
        db.add(device)
        await db.flush()
        logger.info(f"Новое устройство зарегистрировано: {body.device_id}")
    else:
        logger.info(f"Обновление токена для устройства: {body.device_id}")

    if device.is_blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Устройство заблокировано",
        )

    token = create_access_token(subject=body.device_id)
    return TokenResponse(access_token=token)


@router.post("/request-link", status_code=status.HTTP_200_OK, summary="Запрос Magic Link")
async def request_magic_link(
    body: MagicLinkRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Запрос Magic Link + PIN-код на email.

    В DEV_MODE — сразу возвращает токен (без отправки письма).
    """
    email = body.email.lower().strip()

    # DEV_MODE — возвращаем токен сразу
    if settings.DEV_MODE:
        user = await _get_or_create_user(db, email)
        token = create_access_token(subject=f"user:{user.id}")
        return {"message": "DEV_MODE: token выдан напрямую", "token": token, "user_id": user.id}

    # Проверяем белый список (если задан)
    if settings.allowed_emails_list and email not in settings.allowed_emails_list:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Email не в списке разрешённых",
        )

    # Удаляем старые коды для этого email
    await db.execute(
        delete(MagicCode).where(MagicCode.email == email)
    )

    # Генерируем PIN-код и сохраняем в БД
    pin_code = _generate_pin()
    magic_code = MagicCode(
        email=email,
        code=pin_code,
        expires_at=datetime.now(timezone.utc) + timedelta(minutes=15),
    )
    db.add(magic_code)
    await db.flush()

    # Создаём Magic Link токен
    token = create_magic_token(email)

    # Определяем base_url
    scheme = request.headers.get("x-forwarded-proto", "https")
    host = request.headers.get("host", "")
    base_url = f"{scheme}://{host}"

    sent = await send_magic_link(email, token, base_url, pin_code)

    if not sent:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Не удалось отправить письмо",
        )

    return {"message": "Ссылка и код для входа отправлены на email"}


@router.get("/verify", summary="Верификация Magic Link")
async def verify_magic_link_get(
    token: str = Query(...),
    db: AsyncSession = Depends(get_db),
):
    """Верификация Magic Link → редирект с access token."""
    payload = verify_token(token)
    if not payload or payload.get("purpose") != "magic_link":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Невалидная или просроченная ссылка",
        )

    email = payload.get("sub")
    if not email:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Невалидный токен",
        )

    user = await _get_or_create_user(db, email)

    # Удаляем использованные коды
    await db.execute(delete(MagicCode).where(MagicCode.email == email))

    # Выдаём долгоживущий access token
    access_token = create_access_token(subject=f"user:{user.id}")

    # Редирект (для web) или JSON (для API)
    return {"access_token": access_token, "token_type": "bearer", "user_id": user.id}


@router.post("/verify-pin", response_model=TokenResponse, summary="Верификация PIN-кода")
async def verify_pin(
    body: PinVerifyRequest,
    db: AsyncSession = Depends(get_db),
):
    """Верификация по PIN-коду → привязка device к user → выдача access token."""
    email = body.email.lower().strip()
    code = body.code.strip()

    # Ищем валидный код
    result = await db.execute(
        select(MagicCode).where(
            MagicCode.email == email,
            MagicCode.code == code,
            MagicCode.used == False,  # noqa: E712
            MagicCode.expires_at > datetime.now(timezone.utc),
        )
    )
    magic_code = result.scalar_one_or_none()

    if not magic_code:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный или просроченный код",
        )

    # Удаляем все коды для email
    await db.execute(delete(MagicCode).where(MagicCode.email == email))

    # Создаём/получаем пользователя
    user = await _get_or_create_user(db, email)

    # Привязываем device к user
    result = await db.execute(
        select(Device).where(Device.device_id == body.device_id)
    )
    device = result.scalar_one_or_none()
    
    if not device:
        # Если устройства нет в БД (например, удалили вручную), создаём его
        device = Device(device_id=body.device_id, user_id=user.id)
        db.add(device)
        await db.flush()
        logger.info(f"Создано новое устройство {body.device_id} и привязано к {user.id}")
    else:
        # Устройство существует. Если оно было привязано к другому юзеру (или ни к кому), перепривязываем:
        if device.user_id != user.id:
            logger.info(f"Устройство {body.device_id} перепривязано от {device.user_id} к {user.id}")
            device.user_id = user.id
            await db.flush()

    # Выдаём access token
    access_token = create_access_token(subject=body.device_id)
    return TokenResponse(access_token=access_token)


@router.get("/me", response_model=UserResponse, summary="Текущий пользователь")
async def get_me(user: User = Depends(require_user)):
    """Получение информации о текущем пользователе."""
    return user


@router.post("/link-device", summary="Привязка устройства к аккаунту")
async def link_device(
    body: LinkDeviceRequest,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Привязывает устройство к текущему авторизованному пользователю.

    Используется когда пользователь авторизовался на одном устройстве
    и хочет привязать другое.
    """
    result = await db.execute(
        select(Device).where(Device.device_id == body.device_id)
    )
    device = result.scalar_one_or_none()

    if not device:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Устройство не найдено",
        )

    if device.user_id is not None and device.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Устройство уже привязано к другому аккаунту",
        )

    device.user_id = user.id
    await db.flush()

    logger.info(f"Устройство {body.device_id} привязано к пользователю {user.id}")
    return {"message": "Устройство привязано к аккаунту", "user_id": user.id}


@router.delete("/account", summary="Удаление аккаунта")
async def delete_account(
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Полное удаление аккаунта и всех данных пользователя.

    Требование Apple App Store Review Guidelines 5.1.1(v):
    приложение с авторизацией обязано поддерживать удаление аккаунта.

    Каскадно удаляются: transactions, categories, counterparts,
    debts, debt_payments, user_settings.
    Devices отвязываются (user_id = NULL), но НЕ удаляются.
    """
    from sqlalchemy import update

    user_id = user.id
    user_email = user.email
    logger.info(f"Удаление аккаунта: user_id={user_id}, email={user_email}")

    # Удаляем magic codes для этого email
    if user_email:
        await db.execute(delete(MagicCode).where(MagicCode.email == user_email))

    # Отвязываем devices — устройство физическое, продолжает жить
    await db.execute(
        update(Device).where(Device.user_id == user_id).values(user_id=None)
    )

    # Удаляем пользователя — каскад удалит все данные (кроме devices)
    await db.delete(user)
    await db.flush()

    logger.info(f"Аккаунт удалён: user_id={user_id}, email={user_email}")
    return {"message": "Аккаунт и все данные удалены"}


@router.post("/logout", summary="Выход")
async def logout():
    """Логаут — клиент удаляет токен локально."""
    return {"message": "Logged out"}
