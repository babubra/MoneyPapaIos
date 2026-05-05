"""FastAPI dependencies — аутентификация и авторизация (Auth Model C).

После миграции на обязательную авторизацию (SiwA + magic-link) единственная
форма идентификации — User. Device остаётся как локальная метаданные (для
будущей телеметрии), но не участвует в JWT-валидации.

JWT subject имеет формат ``user:{id}``. Старые токены с subject==<UUID device_id>
отвергаются (returns None из ``get_current_user`` → 401 в ``require_user``).

В DEV_MODE без токена создаётся dev-пользователь (см. ``_dev_auto_user``).
"""

from __future__ import annotations

import logging

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.security import decode_access_token
from app.db.models import User, UserSettings
from app.db.session import get_db

logger = logging.getLogger(__name__)
settings = get_settings()

# auto_error=False — обрабатываем 401 сами с понятным detail.
security = HTTPBearer(auto_error=False)

USER_SUBJECT_PREFIX = "user:"


async def _dev_auto_user(db: AsyncSession) -> User:
    """Создаёт/возвращает dev-пользователя (только в DEV_MODE).

    Email берётся из ALLOWED_EMAILS либо дефолтный ``dev@monpapa.local``.
    Логирует WARNING при каждом вызове — это auto-login, который не должен
    случаться в проде.
    """
    dev_email = (
        settings.allowed_emails_list[0]
        if settings.allowed_emails_list
        else "dev@monpapa.local"
    )
    result = await db.execute(select(User).where(User.email == dev_email))
    user = result.scalar_one_or_none()
    if user is None:
        user = User(email=dev_email, display_name="Developer")
        db.add(user)
        await db.flush()
        db.add(UserSettings(user_id=user.id))
        await db.flush()
        logger.warning("DEV_MODE: создан dev-пользователь %s (auto-login)", dev_email)
    else:
        logger.warning("DEV_MODE: auto-login как %s", dev_email)
    return user


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    db: AsyncSession = Depends(get_db),
) -> User | None:
    """Возвращает User из JWT subject ``user:{id}``.

    Возвращает None если:
      • токена нет
      • токен невалиден / просрочен
      • subject не имеет префикс ``user:`` (старые device-токены)
      • пользователя с таким id больше нет в БД

    В DEV_MODE без токена возвращает dev-пользователя.
    """
    if credentials is None:
        if settings.DEV_MODE:
            return await _dev_auto_user(db)
        return None

    subject = decode_access_token(credentials.credentials)
    if subject is None:
        return None

    if not subject.startswith(USER_SUBJECT_PREFIX):
        # Это старый device-токен, выпущенный до миграции на Auth Model C.
        # Клиенты должны переавторизоваться через /auth/apple или /auth/verify-pin.
        logger.info("Отклонён legacy device-токен (subject=%s...)", subject[:8])
        return None

    raw_id = subject[len(USER_SUBJECT_PREFIX):]
    try:
        user_id = int(raw_id)
    except ValueError:
        logger.warning("Невалидный user_id в JWT subject: %r", raw_id)
        return None

    result = await db.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()


async def require_user(
    user: User | None = Depends(get_current_user),
) -> User:
    """Требует авторизованного пользователя. 401 если нет/невалиден."""
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация. Войдите через Sign in with Apple или Magic Link.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user
