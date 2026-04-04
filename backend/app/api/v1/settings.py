"""API — Настройки пользователя.

GET  /api/v1/settings — получить настройки
PUT  /api/v1/settings — обновить настройки

Настройки хранятся на сервере для синхронизации между устройствами.
sync_enabled определяет, нужно ли подтягивать данные при логине на новом устройстве.
"""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.db.models import User, UserSettings
from app.db.session import get_db
from app.schemas import UserSettingsResponse, UserSettingsUpdate

router = APIRouter()


async def _get_or_create_settings(db: AsyncSession, user: User) -> UserSettings:
    """Получает или создаёт настройки для пользователя."""
    from sqlalchemy import select

    result = await db.execute(
        select(UserSettings).where(UserSettings.user_id == user.id)
    )
    existing = result.scalar_one_or_none()
    if existing:
        return existing

    new_settings = UserSettings(user_id=user.id)
    db.add(new_settings)
    await db.flush()
    await db.refresh(new_settings)
    return new_settings


@router.get("", response_model=UserSettingsResponse)
async def get_settings(
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Получение настроек текущего пользователя."""
    settings = await _get_or_create_settings(db, user)
    return settings


@router.put("", response_model=UserSettingsResponse)
async def update_settings(
    body: UserSettingsUpdate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Обновление настроек пользователя.

    Частичное обновление — передавайте только те поля, которые хотите изменить.
    """
    settings = await _get_or_create_settings(db, user)

    update_data = body.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(settings, field, value)

    await db.flush()
    await db.refresh(settings)
    return settings
