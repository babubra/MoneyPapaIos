"""Pydantic-схемы — AI-парсинг + CRUD для всех сущностей."""

from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, Field


# ── AI-парсинг ────────────────────────────────────────────────────

class CategoryContext(BaseModel):
    """Категория пользователя, передаваемая клиентом при AI-запросе."""
    id: str = Field(..., description="Локальный ID категории (из SwiftData)")
    name: str = Field(..., description="Название (или 'Родитель / Дочерняя')")
    type: str = Field(..., pattern=r"^(income|expense)$")
    ai_hint: str | None = None


class CounterpartContext(BaseModel):
    """Контрагент пользователя, передаваемый клиентом при AI-запросе."""
    id: str = Field(..., description="Локальный ID контрагента (из SwiftData)")
    name: str
    ai_hint: str | None = None


class ParseTextRequest(BaseModel):
    """Тело запроса для текстового парсинга."""
    text: str = Field(..., min_length=1, max_length=500)
    categories: list[CategoryContext] = Field(default_factory=list)
    counterparts: list[CounterpartContext] = Field(default_factory=list)
    locale: str = Field(default="ru", max_length=5, description="Языковая локаль клиента")


class RateLimitInfo(BaseModel):
    """Информация о лимитах текущего устройства."""
    requests_today: int
    requests_limit: int
    requests_remaining: int


# ── Category ─────────────────────────────────────────────────────

class CategoryCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    type: str = Field(..., pattern=r"^(income|expense)$")
    parent_id: int | None = None
    icon: str | None = None
    ai_hint: str | None = None
    client_id: str | None = None


class CategoryUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=255)
    type: str | None = Field(None, pattern=r"^(income|expense)$")
    parent_id: int | None = None
    icon: str | None = None
    ai_hint: str | None = None


class CategoryResponse(BaseModel):
    id: int
    client_id: str | None
    parent_id: int | None
    name: str
    type: str
    icon: str | None
    ai_hint: str | None
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None

    model_config = {"from_attributes": True}


# ── Counterpart ──────────────────────────────────────────────────

class CounterpartCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    icon: str | None = None
    ai_hint: str | None = None
    client_id: str | None = None


class CounterpartUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=255)
    icon: str | None = None
    ai_hint: str | None = None


class CounterpartResponse(BaseModel):
    id: int
    client_id: str | None
    name: str
    icon: str | None
    ai_hint: str | None
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None

    model_config = {"from_attributes": True}


# ── Transaction ──────────────────────────────────────────────────

class TransactionCreate(BaseModel):
    category_id: int | None = None
    type: str = Field(..., pattern=r"^(income|expense)$")
    amount: Decimal = Field(..., gt=0)
    currency: str = "RUB"
    comment: str | None = None
    raw_text: str | None = None
    client_id: str | None = None
    transaction_date: date


class TransactionUpdate(BaseModel):
    category_id: int | None = None
    type: str | None = Field(None, pattern=r"^(income|expense)$")
    amount: Decimal | None = Field(None, gt=0)
    currency: str | None = None
    comment: str | None = None
    transaction_date: date | None = None


class TransactionResponse(BaseModel):
    id: int
    client_id: str | None
    category_id: int | None
    category_name: str | None = None
    category_icon: str | None = None
    type: str
    amount: Decimal
    currency: str
    comment: str | None
    raw_text: str | None
    transaction_date: date
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None

    model_config = {"from_attributes": True}


class TransactionSummary(BaseModel):
    month: str  # "2026-03"
    total_income: Decimal
    total_expense: Decimal
    balance: Decimal


# ── Debt ─────────────────────────────────────────────────────────

class DebtCreate(BaseModel):
    counterpart_id: int | None = None
    direction: str = Field(..., pattern=r"^(gave|took)$")
    amount: Decimal = Field(..., gt=0)
    currency: str = "RUB"
    comment: str | None = None
    raw_text: str | None = None
    client_id: str | None = None
    debt_date: date
    due_date: date | None = None


class DebtUpdate(BaseModel):
    counterpart_id: int | None = None
    direction: str | None = Field(None, pattern=r"^(gave|took)$")
    amount: Decimal | None = Field(None, gt=0)
    currency: str | None = None
    comment: str | None = None
    debt_date: date | None = None
    due_date: date | None = None
    is_closed: bool | None = None


class DebtPaymentCreate(BaseModel):
    amount: Decimal = Field(..., gt=0)
    payment_date: date
    comment: str | None = None
    client_id: str | None = None


class DebtPaymentResponse(BaseModel):
    id: int
    client_id: str | None
    debt_id: int
    amount: Decimal
    payment_date: date
    comment: str | None
    created_at: datetime
    deleted_at: datetime | None = None

    model_config = {"from_attributes": True}


class DebtResponse(BaseModel):
    id: int
    client_id: str | None
    counterpart_id: int | None
    counterpart_name: str | None = None
    direction: str
    amount: Decimal
    paid_amount: Decimal
    currency: str
    comment: str | None
    raw_text: str | None
    debt_date: date
    due_date: date | None
    is_closed: bool
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None
    payments: list[DebtPaymentResponse] = []

    model_config = {"from_attributes": True}


# ── UserSettings ─────────────────────────────────────────────────

class UserSettingsUpdate(BaseModel):
    sync_enabled: bool | None = None
    default_currency: str | None = Field(None, max_length=10)
    theme: str | None = Field(None, pattern=r"^(dark|light|system)$")
    custom_prompt: str | None = None


class UserSettingsResponse(BaseModel):
    id: int
    sync_enabled: bool
    default_currency: str
    theme: str
    custom_prompt: str | None

    model_config = {"from_attributes": True}

