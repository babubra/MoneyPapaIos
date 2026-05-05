"""Auth API — обязательная авторизация (Auth Model C).

Эндпоинты:
- POST /api/v1/auth/apple        — Sign in with Apple (identity_token → JWT)
- POST /api/v1/auth/request-link — запрос Magic Link + PIN на email
- POST /api/v1/auth/verify-pin   — верификация PIN → JWT
- GET  /api/v1/auth/verify       — верификация Magic Link (для web-fallback)
- GET  /api/v1/auth/me           — текущий пользователь
- DELETE /api/v1/auth/account    — удаление аккаунта (Apple Guidelines 5.1.1(v))
- POST /api/v1/auth/logout       — no-op (клиент удаляет токен)

Анонимный device-режим удалён: ``/auth/device`` больше нет, JWT теперь всегда
``subject="user:{id}"``.
"""

from __future__ import annotations

import logging
import random
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.core.apple_auth import verify_apple_identity_token
from app.core.config import get_settings
from app.core.email import send_magic_link
from app.core.rate_limit import (
    apple_signin_limiter,
    magic_link_limiter,
    pin_verify_limiter,
)
from app.core.security import create_access_token, create_magic_token, verify_token
from app.db.models import CategoryMapping, Device, MagicCode, User, UserSettings
from app.db.session import get_db

logger = logging.getLogger(__name__)
router = APIRouter()
settings = get_settings()


def _user_subject(user: User) -> str:
    """JWT subject для user-токенов: ``user:{id}``."""
    return f"user:{user.id}"


# ── Pydantic-схемы (локальные для auth) ──────────────────────────

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
    # device_id остаётся в запросе для backward compatibility iOS-клиента и
    # для метаданных (last_seen_at). Не участвует в JWT.
    device_id: str = Field(..., min_length=36, max_length=36)


class AppleSignInRequest(BaseModel):
    """Sign in with Apple — body для POST /auth/apple.

    full_name приходит ТОЛЬКО при первой авторизации (Apple так устроен).
    """
    identity_token: str = Field(..., min_length=8)
    device_id: str = Field(..., min_length=36, max_length=36)
    full_name: str | None = Field(default=None, max_length=255)


class UserResponse(BaseModel):
    """Информация о текущем пользователе."""
    id: int
    email: str | None
    display_name: str | None
    apple_user_id: str | None = None
    subscription_status: str
    ai_trial_used: int
    created_at: datetime

    model_config = {"from_attributes": True}


# ── Вспомогательные функции ──────────────────────────────────────

def _generate_pin() -> str:
    """Генерирует 6-значный PIN-код."""
    return f"{random.randint(100000, 999999)}"


async def _ensure_user_settings(db: AsyncSession, user: User) -> None:
    """Создаёт UserSettings для нового user'а (если ещё нет)."""
    existing = await db.execute(
        select(UserSettings).where(UserSettings.user_id == user.id)
    )
    if existing.scalar_one_or_none() is None:
        db.add(UserSettings(user_id=user.id))
        await db.flush()


async def _get_or_create_user_by_email(db: AsyncSession, email: str) -> User:
    """Получает или создаёт пользователя по email (magic-link flow)."""
    result = await db.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user:
        user = User(email=email)
        db.add(user)
        await db.flush()
        await _ensure_user_settings(db, user)
        logger.info(f"Новый пользователь создан (email): {email}")
    return user


async def _get_or_create_user_by_apple_sub(
    db: AsyncSession,
    apple_sub: str,
    email: str | None,
    full_name: str | None,
) -> User:
    """Получает или создаёт пользователя по Apple stable sub."""
    result = await db.execute(select(User).where(User.apple_user_id == apple_sub))
    user = result.scalar_one_or_none()
    if user:
        # Обновляем display_name только если он ещё не задан и сейчас пришло что-то.
        if not user.display_name and full_name:
            user.display_name = full_name
            await db.flush()
        return user

    # Если у нас уже есть user с таким email (вошёл через magic-link), привязываем
    # к нему apple_user_id, чтобы избежать дубликата.
    if email:
        existing = await db.execute(select(User).where(User.email == email))
        user = existing.scalar_one_or_none()
        if user:
            user.apple_user_id = apple_sub
            if full_name and not user.display_name:
                user.display_name = full_name
            await db.flush()
            logger.info(f"Apple sub привязан к существующему user_id={user.id} email={email}")
            return user

    user = User(email=email, apple_user_id=apple_sub, display_name=full_name)
    db.add(user)
    await db.flush()
    await _ensure_user_settings(db, user)
    logger.info(f"Новый пользователь создан (Apple): apple_sub={apple_sub} email={email}")
    return user


async def _attach_device(db: AsyncSession, device_id: str, user: User) -> None:
    """Привязывает device к user (создаёт Device если не существует).

    Device больше не участвует в JWT, но остаётся как метаданные / для будущих
    нужд (per-device telemetry, push-notifications).
    """
    result = await db.execute(select(Device).where(Device.device_id == device_id))
    device = result.scalar_one_or_none()
    if device is None:
        device = Device(device_id=device_id, user_id=user.id)
        db.add(device)
        await db.flush()
        logger.info(f"Создано новое устройство {device_id[:8]}... привязано к user_id={user.id}")
    elif device.user_id != user.id:
        logger.info(
            f"Устройство {device_id[:8]}... перепривязано "
            f"(user_id: {device.user_id} → {user.id})"
        )
        device.user_id = user.id
        await db.flush()


# ── Эндпоинты ────────────────────────────────────────────────────

@router.post(
    "/apple",
    response_model=TokenResponse,
    summary="Sign in with Apple",
)
async def auth_apple(
    body: AppleSignInRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
) -> TokenResponse:
    """Принимает Apple identity_token, проверяет через JWKS, выдаёт user-токен.

    DEV_MODE: ``identity_token == "DEV_STUB"`` обходит проверку (см. apple_auth.py).
    """
    apple_signin_limiter.check(request)

    payload = await verify_apple_identity_token(
        body.identity_token,
        dev_stub_device_id=body.device_id,
    )
    apple_sub: str = payload["sub"]
    email: str | None = payload.get("email")
    if email:
        email = email.lower().strip()

    user = await _get_or_create_user_by_apple_sub(
        db,
        apple_sub=apple_sub,
        email=email,
        full_name=body.full_name,
    )
    await _attach_device(db, body.device_id, user)

    token = create_access_token(subject=_user_subject(user))
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
    magic_link_limiter.check(request)

    email = body.email.lower().strip()

    # DEV_MODE — возвращаем токен сразу
    if settings.DEV_MODE:
        user = await _get_or_create_user_by_email(db, email)
        token = create_access_token(subject=_user_subject(user))
        return {
            "message": "DEV_MODE: token выдан напрямую",
            "token": token,
            "user_id": user.id,
        }

    # Проверяем белый список (если задан)
    if settings.allowed_emails_list and email not in settings.allowed_emails_list:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Email не в списке разрешённых",
        )

    # Удаляем старые коды для этого email
    await db.execute(delete(MagicCode).where(MagicCode.email == email))

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


@router.get("/verify", summary="Верификация Magic Link (web-fallback)")
async def verify_magic_link_get(
    token: str = Query(...),
    db: AsyncSession = Depends(get_db),
):
    """Верификация Magic Link — JSON с access_token (web-fallback).

    iOS-клиент использует ``/verify-pin`` — там и привязка устройства.
    """
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

    user = await _get_or_create_user_by_email(db, email)

    # Удаляем использованные коды
    await db.execute(delete(MagicCode).where(MagicCode.email == email))

    access_token = create_access_token(subject=_user_subject(user))
    return {"access_token": access_token, "token_type": "bearer", "user_id": user.id}


@router.post("/verify-pin", response_model=TokenResponse, summary="Верификация PIN-кода")
async def verify_pin(
    body: PinVerifyRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Верификация по PIN-коду → привязка device → выдача user-токена."""
    pin_verify_limiter.check(request)

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

    # Удаляем все коды для email (одноразовость)
    await db.execute(delete(MagicCode).where(MagicCode.email == email))

    user = await _get_or_create_user_by_email(db, email)
    await _attach_device(db, body.device_id, user)

    access_token = create_access_token(subject=_user_subject(user))
    return TokenResponse(access_token=access_token)


@router.get("/me", response_model=UserResponse, summary="Текущий пользователь")
async def get_me(user: User = Depends(require_user)):
    """Получение информации о текущем пользователе."""
    return user


@router.delete("/account", summary="Удаление аккаунта")
async def delete_account(
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Полное удаление аккаунта и всех данных пользователя.

    Требование Apple App Store Review Guidelines 5.1.1(v).

    Каскадно удаляются: transactions, categories, counterparts,
    debts, debt_payments, user_settings, category_mappings.
    Devices отвязываются (user_id = NULL), но НЕ удаляются физически.
    """
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

    # Удаляем category_mappings вручную — в моделях исторически отсутствовал
    # ondelete="CASCADE" на CategoryMapping.user_id (исправлено для новых БД,
    # но в существующих pgdata-volume FK без CASCADE). Этот явный delete
    # обеспечивает корректное удаление аккаунта на текущей dev-БД без
    # сброса pgdata. Можно убрать после `docker compose down -v && up`.
    await db.execute(delete(CategoryMapping).where(CategoryMapping.user_id == user_id))

    # Удаляем пользователя — каскад удалит все остальные данные (кроме devices)
    await db.delete(user)
    await db.flush()

    logger.info(f"Аккаунт удалён: user_id={user_id}, email={user_email}")
    return {"message": "Аккаунт и все данные удалены"}


@router.post("/logout", summary="Выход")
async def logout():
    """Логаут — клиент удаляет токен локально."""
    return {"message": "Logged out"}
