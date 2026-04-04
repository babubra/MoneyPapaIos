"""CRUD API — Долги и платежи по долгам.

Все операции требуют авторизованного пользователя (require_user).
Удаление — soft delete (deleted_at).
Платежи автоматически обновляют paid_amount и is_closed.
"""

from datetime import datetime, timezone
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.api.deps import require_user
from app.db.models import Debt, DebtPayment, User
from app.db.session import get_db
from app.schemas import (
    DebtCreate,
    DebtPaymentCreate,
    DebtPaymentResponse,
    DebtResponse,
    DebtUpdate,
)

router = APIRouter()


@router.get("", response_model=list[DebtResponse])
async def list_debts(
    is_closed: bool | None = None,
    direction: str | None = Query(None, pattern=r"^(gave|took)$"),
    include_deleted: bool = Query(False),
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Список долгов. Опциональные фильтры: is_closed, direction."""
    query = (
        select(Debt)
        .options(joinedload(Debt.counterpart), joinedload(Debt.payments))
        .where(Debt.user_id == user.id)
    )

    if not include_deleted:
        query = query.where(Debt.deleted_at.is_(None))

    if is_closed is not None:
        query = query.where(Debt.is_closed == is_closed)
    if direction:
        query = query.where(Debt.direction == direction)

    query = query.order_by(Debt.debt_date.desc(), Debt.id.desc())

    result = await db.execute(query)
    debts = result.unique().scalars().all()

    # Добавляем counterpart_name
    response = []
    for d in debts:
        data = DebtResponse.model_validate(d)
        data.counterpart_name = d.counterpart.name if d.counterpart else None
        response.append(data)

    return response


@router.post("", response_model=DebtResponse, status_code=status.HTTP_201_CREATED)
async def create_debt(
    body: DebtCreate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Создание нового долга."""
    if body.client_id:
        existing = await db.execute(
            select(Debt).where(Debt.client_id == body.client_id)
        )
        if existing.scalar_one_or_none():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Долг с таким client_id уже существует",
            )

    debt = Debt(
        user_id=user.id,
        **body.model_dump(),
    )
    db.add(debt)
    await db.flush()
    await db.refresh(debt, attribute_names=["counterpart", "payments", "created_at", "updated_at"])

    data = DebtResponse.model_validate(debt)
    data.counterpart_name = debt.counterpart.name if debt.counterpart else None
    return data


@router.put("/{debt_id}", response_model=DebtResponse)
async def update_debt(
    debt_id: int,
    body: DebtUpdate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Обновление долга."""
    result = await db.execute(
        select(Debt)
        .options(joinedload(Debt.counterpart), joinedload(Debt.payments))
        .where(
            Debt.id == debt_id,
            Debt.user_id == user.id,
            Debt.deleted_at.is_(None),
        )
    )
    debt = result.unique().scalar_one_or_none()
    if not debt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Долг не найден")

    update_data = body.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(debt, field, value)

    await db.flush()
    await db.refresh(debt, attribute_names=["counterpart", "payments", "created_at", "updated_at"])

    data = DebtResponse.model_validate(debt)
    data.counterpart_name = debt.counterpart.name if debt.counterpart else None
    return data


@router.delete("/{debt_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_debt(
    debt_id: int,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Soft delete долга."""
    result = await db.execute(
        select(Debt).where(
            Debt.id == debt_id,
            Debt.user_id == user.id,
            Debt.deleted_at.is_(None),
        )
    )
    debt = result.scalar_one_or_none()
    if not debt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Долг не найден")

    debt.deleted_at = datetime.now(timezone.utc)


# ── Платежи по долгу ─────────────────────────────────────────────

@router.post("/{debt_id}/payments", response_model=DebtPaymentResponse, status_code=status.HTTP_201_CREATED)
async def add_payment(
    debt_id: int,
    body: DebtPaymentCreate,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Добавление платежа по долгу. Автоматически обновляет paid_amount и is_closed."""
    result = await db.execute(
        select(Debt).where(
            Debt.id == debt_id,
            Debt.user_id == user.id,
            Debt.deleted_at.is_(None),
        )
    )
    debt = result.scalar_one_or_none()
    if not debt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Долг не найден")

    if debt.is_closed:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Долг уже закрыт",
        )

    payment = DebtPayment(
        debt_id=debt.id,
        amount=body.amount,
        payment_date=body.payment_date,
        comment=body.comment,
        client_id=body.client_id,
    )
    db.add(payment)

    # Обновляем paid_amount
    debt.paid_amount = (debt.paid_amount or Decimal("0")) + body.amount

    # Автоматическое закрытие долга
    if debt.paid_amount >= debt.amount:
        debt.is_closed = True

    await db.flush()
    await db.refresh(payment)
    return payment
