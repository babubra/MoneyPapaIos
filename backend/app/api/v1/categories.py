"""CRUD API — Категории.

Все операции требуют авторизованного пользователя (require_user).
Удаление — soft delete (deleted_at).
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.db.models import Category, User
from app.db.session import get_db
from app.schemas import CategoryCreate, CategoryResponse, CategoryUpdate

router = APIRouter()


@router.get("", response_model=list[CategoryResponse])
async def list_categories(
    type: str | None = Query(None, pattern=r"^(income|expense)$"),
    include_deleted: bool = Query(False, description="Включить удалённые"),
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Список категорий текущего пользователя. Опциональный фильтр по типу."""
    query = select(Category).where(Category.user_id == user.id)

    if not include_deleted:
        query = query.where(Category.deleted_at.is_(None))

    if type:
        query = query.where(Category.type == type)

    query = query.order_by(Category.name)

    result = await db.execute(query)
    return result.scalars().all()


@router.post("", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
async def create_category(
    body: CategoryCreate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Создание новой категории."""
    # Дедупликация по client_id
    if body.client_id:
        existing = await db.execute(
            select(Category).where(Category.client_id == body.client_id)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Категория с таким client_id уже существует",
            )

    category = Category(
        user_id=user.id,
        name=body.name,
        type=body.type,
        parent_id=body.parent_id,
        icon=body.icon,
        ai_hint=body.ai_hint,
        client_id=body.client_id,
    )
    db.add(category)
    await db.flush()
    await db.refresh(category)
    return category


@router.put("/{category_id}", response_model=CategoryResponse)
async def update_category(
    category_id: int,
    body: CategoryUpdate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Обновление категории."""
    result = await db.execute(
        select(Category).where(
            Category.id == category_id,
            Category.user_id == user.id,
            Category.deleted_at.is_(None),
        )
    )
    category = result.scalar_one_or_none()
    if not category:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Категория не найдена")

    update_data = body.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(category, field, value)

    await db.flush()
    await db.refresh(category)
    return category


@router.delete("/{category_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_category(
    category_id: int,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Soft delete категории."""
    result = await db.execute(
        select(Category).where(
            Category.id == category_id,
            Category.user_id == user.id,
            Category.deleted_at.is_(None),
        )
    )
    category = result.scalar_one_or_none()
    if not category:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Категория не найдена")

    category.deleted_at = datetime.now(timezone.utc)
