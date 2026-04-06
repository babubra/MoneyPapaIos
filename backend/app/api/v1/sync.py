"""Sync API — батч-синхронизация между устройствами.

POST /api/v1/sync          — отправить batch операций (create/update/delete)
GET  /api/v1/sync/changes  — получить изменения с указанного времени

Стратегия конфликтов: last-write-wins (сравнение updated_at).
Идемпотентность: дедупликация по client_id (повторная отправка не ломает данные).
"""

import logging
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.api.deps import require_user
from app.db.models import (
    Category,
    Counterpart,
    Debt,
    DebtPayment,
    Transaction,
    User,
    UserSettings,
)
from app.db.session import get_db

logger = logging.getLogger(__name__)
router = APIRouter()


# ── Pydantic-схемы для sync ──────────────────────────────────────

class SyncOperation(BaseModel):
    """Одна операция синхронизации."""
    entity: str = Field(..., pattern=r"^(category|transaction|counterpart|debt|debt_payment)$")
    action: str = Field(..., pattern=r"^(create|update|delete)$")
    client_id: str = Field(..., description="UUID записи на клиенте")
    data: dict[str, Any] = Field(default_factory=dict, description="Данные записи")
    updated_at: datetime | None = Field(None, description="Время изменения на клиенте (для LWW)")


class SyncRequest(BaseModel):
    """Batch-запрос на синхронизацию."""
    operations: list[SyncOperation] = Field(default_factory=list)


class SyncOperationResult(BaseModel):
    """Результат одной операции."""
    client_id: str
    status: str  # "created", "updated", "deleted", "skipped", "error"
    server_id: int | None = None
    message: str | None = None


class SyncResponse(BaseModel):
    """Ответ на batch-синхронизацию."""
    results: list[SyncOperationResult]
    server_time: datetime


class SyncChangesResponse(BaseModel):
    """Ответ с изменениями с указанного времени."""
    categories: list["CategoryOut"] = []
    transactions: list["TransactionOut"] = []
    counterparts: list["CounterpartOut"] = []
    debts: list["DebtOut"] = []
    debt_payments: list["DebtPaymentOut"] = []
    settings: "UserSettingsOut | None" = None
    server_time: datetime


# ── Out-схемы (типизированные ответы) ─────────────────────────

class CategoryOut(BaseModel):
    """Схема категории для sync/changes."""
    model_config = {"from_attributes": True}

    id: int
    client_id: str | None = None
    name: str
    type: str
    icon: str | None = None
    ai_hint: str | None = None
    parent_id: int | None = None
    updated_at: datetime
    deleted_at: datetime | None = None


class TransactionOut(BaseModel):
    """Схема транзакции для sync/changes."""
    model_config = {"from_attributes": True}

    id: int
    client_id: str | None = None
    type: str
    amount: Decimal
    currency: str
    transaction_date: date
    comment: str | None = None
    raw_text: str | None = None
    category_id: int | None = None
    updated_at: datetime
    deleted_at: datetime | None = None


class CounterpartOut(BaseModel):
    """Схема контрагента для sync/changes."""
    model_config = {"from_attributes": True}

    id: int
    client_id: str | None = None
    name: str
    icon: str | None = None
    ai_hint: str | None = None
    updated_at: datetime
    deleted_at: datetime | None = None


class DebtOut(BaseModel):
    """Схема долга для sync/changes."""
    model_config = {"from_attributes": True}

    id: int
    client_id: str | None = None
    direction: str
    amount: Decimal
    paid_amount: Decimal
    currency: str
    debt_date: date
    due_date: date | None = None
    comment: str | None = None
    raw_text: str | None = None
    is_closed: bool
    counterpart_id: int | None = None
    updated_at: datetime
    deleted_at: datetime | None = None


class DebtPaymentOut(BaseModel):
    """Схема платежа по долгу для sync/changes."""
    model_config = {"from_attributes": True}

    id: int
    client_id: str | None = None
    amount: Decimal
    payment_date: date
    comment: str | None = None
    debt_id: int
    created_at: datetime
    deleted_at: datetime | None = None


class UserSettingsOut(BaseModel):
    """Схема настроек пользователя."""
    model_config = {"from_attributes": True}

    id: int
    sync_enabled: bool
    default_currency: str
    theme: str
    custom_prompt: str | None = None


# ── Маппинг entity → модель ──────────────────────────────────────

ENTITY_MAP: dict[str, type] = {
    "category": Category,
    "transaction": Transaction,
    "counterpart": Counterpart,
    "debt": Debt,
    "debt_payment": DebtPayment,
}

# Поля, которые нельзя менять через sync
PROTECTED_FIELDS = {"id", "user_id", "created_at", "updated_at", "deleted_at"}


# ── Утилиты ──────────────────────────────────────────────────────

def _serialize_row(row) -> dict[str, Any]:
    """Конвертирует SQLAlchemy-объект в словарь для JSON.
    
    Даты нормализуются в формат RFC 3339 с 'Z' вместо '+00:00'
    и без микросекунд — для совместимости с iOS ISO8601DateFormatter.
    """
    result = {}
    for col in row.__table__.columns:
        value = getattr(row, col.name)
        if isinstance(value, datetime):
            result[col.name] = value.replace(microsecond=0).isoformat().replace("+00:00", "Z")
        elif isinstance(value, Decimal):
            result[col.name] = str(value)
        elif hasattr(value, 'isoformat'):  # date
            result[col.name] = value.isoformat()
        else:
            result[col.name] = value
    return result


def _get_user_id_field(entity: str) -> str | None:
    """Возвращает имя поля user_id для сущности, или None если его нет."""
    if entity == "debt_payment":
        return None  # debt_payment привязан к debt, а не к user
    return "user_id"


def _coerce_data_types(Model, data: dict[str, Any]) -> dict[str, Any]:
    """Конвертирует строковые значения в нативные Python-типы.

    asyncpg требует date, Decimal и т.д., а не строки из JSON.
    """
    from datetime import date as date_type
    from sqlalchemy import inspect as sa_inspect

    coerced = {}
    mapper = sa_inspect(Model)
    col_types = {col.name: col.type for col in mapper.columns}

    for key, value in data.items():
        if value is None or key not in col_types:
            coerced[key] = value
            continue

        col_type = col_types[key]
        type_name = type(col_type).__name__

        try:
            if type_name == "Date" and isinstance(value, str):
                coerced[key] = date_type.fromisoformat(value)
            elif type_name == "Numeric" and isinstance(value, (str, int, float)):
                coerced[key] = Decimal(str(value))
            elif type_name in ("DateTime",) and isinstance(value, str):
                coerced[key] = datetime.fromisoformat(value)
            elif type_name == "Boolean" and isinstance(value, (str, int)):
                coerced[key] = bool(value) if isinstance(value, int) else value.lower() in ("true", "1")
            elif type_name == "Integer" and isinstance(value, str):
                coerced[key] = int(value)
            else:
                coerced[key] = value
        except (ValueError, TypeError):
            coerced[key] = value

    return coerced


# ── POST /sync — batch-операции ──────────────────────────────────

@router.post("", response_model=SyncResponse, summary="Batch-синхронизация")
async def sync_batch(
    body: SyncRequest,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Принимает batch операций от клиента и применяет к БД.

    Стратегия:
    - create: создаёт или пропускает (если client_id уже есть → идемпотентность)
    - update: обновляет, если серверная updated_at <= клиентской (last-write-wins)
    - delete: soft delete (проставляет deleted_at)
    """
    results: list[SyncOperationResult] = []
    now = datetime.now(timezone.utc)

    for op in body.operations:
        try:
            result = await _process_operation(db, user, op, now)
            results.append(result)
        except Exception as e:
            logger.error(f"Sync error: entity={op.entity} action={op.action} client_id={op.client_id}: {e}")
            results.append(SyncOperationResult(
                client_id=op.client_id,
                status="error",
                message=str(e),
            ))

    await db.flush()

    return SyncResponse(results=results, server_time=now)


async def _process_operation(
    db: AsyncSession,
    user: User,
    op: SyncOperation,
    now: datetime,
) -> SyncOperationResult:
    """Обрабатывает одну sync-операцию."""
    Model = ENTITY_MAP.get(op.entity)
    if not Model:
        return SyncOperationResult(
            client_id=op.client_id,
            status="error",
            message=f"Неизвестная сущность: {op.entity}",
        )

    if op.action == "create":
        return await _sync_create(db, user, Model, op, now)
    elif op.action == "update":
        return await _sync_update(db, user, Model, op, now)
    elif op.action == "delete":
        return await _sync_delete(db, user, Model, op, now)
    else:
        return SyncOperationResult(
            client_id=op.client_id,
            status="error",
            message=f"Неизвестное действие: {op.action}",
        )


async def _sync_create(
    db: AsyncSession, user: User, Model, op: SyncOperation, now: datetime
) -> SyncOperationResult:
    """Create: создаёт или возвращает существующую запись (идемпотентность по client_id)."""
    # Ищем по client_id — может уже существовать (retry от клиента)
    result = await db.execute(
        select(Model).where(Model.client_id == op.client_id)
    )
    existing = result.scalar_one_or_none()

    if existing:
        return SyncOperationResult(
            client_id=op.client_id,
            status="skipped",
            server_id=existing.id,
            message="Запись уже существует",
        )

    # Подготавливаем данные
    data = {k: v for k, v in op.data.items() if k not in PROTECTED_FIELDS}
    data["client_id"] = op.client_id
    data = _coerce_data_types(Model, data)

    # Привязка к пользователю
    user_id_field = _get_user_id_field(op.entity)
    if user_id_field:
        data[user_id_field] = user.id

    # Для debt_payment — проверяем что долг принадлежит пользователю
    if op.entity == "debt_payment" and "debt_id" in data:
        debt_result = await db.execute(
            select(Debt).where(Debt.id == data["debt_id"], Debt.user_id == user.id)
        )
        if not debt_result.scalar_one_or_none():
            return SyncOperationResult(
                client_id=op.client_id,
                status="error",
                message="Долг не найден",
            )

    row = Model(**data)
    db.add(row)
    await db.flush()

    return SyncOperationResult(
        client_id=op.client_id,
        status="created",
        server_id=row.id,
    )


async def _sync_update(
    db: AsyncSession, user: User, Model, op: SyncOperation, now: datetime
) -> SyncOperationResult:
    """Update: обновляет по client_id с last-write-wins."""
    result = await db.execute(
        select(Model).where(Model.client_id == op.client_id)
    )
    existing = result.scalar_one_or_none()

    if not existing:
        return SyncOperationResult(
            client_id=op.client_id,
            status="error",
            message="Запись не найдена",
        )

    # Проверяем принадлежность пользователю
    user_id_field = _get_user_id_field(op.entity)
    if user_id_field and getattr(existing, user_id_field) != user.id:
        return SyncOperationResult(
            client_id=op.client_id,
            status="error",
            message="Доступ запрещён",
        )

    # Last-write-wins: если клиентское updated_at <= серверного, пропускаем
    if op.updated_at and hasattr(existing, "updated_at") and existing.updated_at:
        client_time = op.updated_at.replace(tzinfo=timezone.utc) if op.updated_at.tzinfo is None else op.updated_at
        server_time = existing.updated_at.replace(tzinfo=timezone.utc) if existing.updated_at.tzinfo is None else existing.updated_at
        if client_time <= server_time:
            return SyncOperationResult(
                client_id=op.client_id,
                status="skipped",
                server_id=existing.id,
                message="Серверная версия новее",
            )

    # Обновляем поля
    data = {k: v for k, v in op.data.items() if k not in PROTECTED_FIELDS}
    data = _coerce_data_types(Model, data)
    for field, value in data.items():
        if hasattr(existing, field):
            setattr(existing, field, value)

    await db.flush()

    return SyncOperationResult(
        client_id=op.client_id,
        status="updated",
        server_id=existing.id,
    )


async def _sync_delete(
    db: AsyncSession, user: User, Model, op: SyncOperation, now: datetime
) -> SyncOperationResult:
    """Delete: soft delete по client_id."""
    result = await db.execute(
        select(Model).where(Model.client_id == op.client_id)
    )
    existing = result.scalar_one_or_none()

    if not existing:
        return SyncOperationResult(
            client_id=op.client_id,
            status="skipped",
            message="Запись не найдена (возможно, уже удалена)",
        )

    # Проверяем принадлежность
    user_id_field = _get_user_id_field(op.entity)
    if user_id_field and getattr(existing, user_id_field) != user.id:
        return SyncOperationResult(
            client_id=op.client_id,
            status="error",
            message="Доступ запрещён",
        )

    # Soft delete
    if hasattr(existing, "deleted_at"):
        existing.deleted_at = now
    await db.flush()

    return SyncOperationResult(
        client_id=op.client_id,
        status="deleted",
        server_id=existing.id,
    )


# ── GET /changes — дельта-синхронизация ──────────────────────────

@router.get("/changes", response_model=SyncChangesResponse, summary="Получить изменения")
async def get_changes(
    since: datetime = Query(
        ...,
        description="ISO timestamp — получить изменения с этого момента. Для полной выгрузки: 1970-01-01T00:00:00Z",
    ),
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Возвращает все записи, изменённые или удалённые после `since`.

    Используется для:
    1. Первой полной загрузки (since=1970-01-01T00:00:00Z)
    2. Инкрементальной синхронизации (since=last_server_time)

    Ответ включает `server_time` — клиент сохраняет его для следующего запроса.
    """
    now = datetime.now(timezone.utc)

    # Нормализуем timezone
    if since.tzinfo is None:
        since = since.replace(tzinfo=timezone.utc)

    # Загружаем все изменённые/удалённые записи для каждой сущности
    categories = await _get_entity_changes(db, Category, user.id, since)
    transactions = await _get_entity_changes(db, Transaction, user.id, since)
    counterparts = await _get_entity_changes(db, Counterpart, user.id, since)
    debts = await _get_entity_changes(db, Debt, user.id, since)
    debt_payments = await _get_debt_payment_changes(db, user.id, since)

    # Настройки
    settings_out = None
    settings_result = await db.execute(
        select(UserSettings).where(UserSettings.user_id == user.id)
    )
    user_settings = settings_result.scalar_one_or_none()
    if user_settings:
        settings_out = UserSettingsOut.model_validate(user_settings)

    return SyncChangesResponse(
        categories=[CategoryOut.model_validate(r) for r in categories],
        transactions=[TransactionOut.model_validate(r) for r in transactions],
        counterparts=[CounterpartOut.model_validate(r) for r in counterparts],
        debts=[DebtOut.model_validate(r) for r in debts],
        debt_payments=[DebtPaymentOut.model_validate(r) for r in debt_payments],
        settings=settings_out,
        server_time=now,
    )


async def _get_entity_changes(
    db: AsyncSession, Model, user_id: int, since: datetime
):
    """Загружает записи сущности, изменённые/удалённые после since (включительно)."""
    query = select(Model).where(
        Model.user_id == user_id,
        or_(
            Model.updated_at >= since,
            Model.deleted_at >= since,
        ),
    )
    result = await db.execute(query)
    return result.scalars().all()


async def _get_debt_payment_changes(
    db: AsyncSession, user_id: int, since: datetime
):
    """Загружает платежи по долгам, изменённые после since.

    DebtPayment не имеет user_id — фильтруем через debt.user_id.
    """
    query = (
        select(DebtPayment)
        .join(Debt, DebtPayment.debt_id == Debt.id)
        .where(
            Debt.user_id == user_id,
            DebtPayment.created_at >= since,
        )
    )
    result = await db.execute(query)
    return result.scalars().all()
