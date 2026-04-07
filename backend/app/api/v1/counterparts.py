"""CRUD API — Контрагенты (субъекты).

Все операции требуют авторизованного пользователя (require_user).
Удаление — soft delete (deleted_at).
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.db.models import Counterpart, User
from app.db.session import get_db
from app.schemas import CounterpartCreate, CounterpartResponse, CounterpartUpdate

router = APIRouter()


@router.get("", response_model=list[CounterpartResponse])
async def list_counterparts(
    include_deleted: bool = Query(False),
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Список контрагентов текущего пользователя."""
    query = select(Counterpart).where(Counterpart.user_id == user.id)

    if not include_deleted:
        query = query.where(Counterpart.deleted_at.is_(None))

    query = query.order_by(Counterpart.name)

    result = await db.execute(query)
    return result.scalars().all()


@router.post("", response_model=CounterpartResponse, status_code=status.HTTP_201_CREATED)
async def create_counterpart(
    body: CounterpartCreate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Создание нового контрагента."""
    if body.client_id:
        existing = await db.execute(
            select(Counterpart).where(Counterpart.client_id == body.client_id)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Контрагент с таким client_id уже существует",
            )

    counterpart = Counterpart(
        user_id=user.id,
        name=body.name,
        icon=body.icon,
        client_id=body.client_id,
    )
    db.add(counterpart)
    await db.flush()
    await db.refresh(counterpart)
    return counterpart


@router.put("/{counterpart_id}", response_model=CounterpartResponse)
async def update_counterpart(
    counterpart_id: int,
    body: CounterpartUpdate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Обновление контрагента."""
    result = await db.execute(
        select(Counterpart).where(
            Counterpart.id == counterpart_id,
            Counterpart.user_id == user.id,
            Counterpart.deleted_at.is_(None),
        )
    )
    counterpart = result.scalar_one_or_none()
    if not counterpart:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Контрагент не найден")

    update_data = body.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(counterpart, field, value)

    await db.flush()
    await db.refresh(counterpart)
    return counterpart


@router.delete("/{counterpart_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_counterpart(
    counterpart_id: int,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Soft delete контрагента."""
    result = await db.execute(
        select(Counterpart).where(
            Counterpart.id == counterpart_id,
            Counterpart.user_id == user.id,
            Counterpart.deleted_at.is_(None),
        )
    )
    counterpart = result.scalar_one_or_none()
    if not counterpart:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Контрагент не найден")

    counterpart.deleted_at = datetime.now(timezone.utc)
