"""SQLAlchemy ORM-модели MonPapa — Фаза 2.

Серверные модели, зеркалящие iOS SwiftData.
Все модели sync-ready: client_id, updated_at, deleted_at.
Полностью async через AsyncSession + asyncpg.
"""

from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


# ── User ─────────────────────────────────────────────────────────

class User(Base):
    """Пользователь — создаётся при авторизации (Magic Link или Sign in with Apple).

    До авторизации пользователь работает анонимно через Device.
    """
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True, index=True)
    apple_user_id: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True, index=True)
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    # Связи
    devices: Mapped[list["Device"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    categories: Mapped[list["Category"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    transactions: Mapped[list["Transaction"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    counterparts: Mapped[list["Counterpart"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    debts: Mapped[list["Debt"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    settings: Mapped["UserSettings | None"] = relationship(back_populates="user", cascade="all, delete-orphan", uselist=False)

    def __repr__(self) -> str:
        return f"<User id={self.id} email={self.email!r}>"


# ── Device ───────────────────────────────────────────────────────

class Device(Base):
    """Устройство пользователя — основная единица идентификации.

    Каждый UUID из iOS Keychain создаёт одну запись Device.
    После авторизации привязывается к User через user_id.
    """
    __tablename__ = "devices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    device_id: Mapped[str] = mapped_column(String(36), unique=True, index=True, nullable=False)

    # Привязка к пользователю (null = анонимный)
    user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )

    # Rate limiting — текстовые запросы (сброс ежедневно)
    ai_requests_today: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ai_requests_date: Mapped[str | None] = mapped_column(String(10), nullable=True)  # YYYY-MM-DD

    # Rate limiting — аудио-запросы (сброс каждый час)
    ai_audio_requests_hour: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ai_audio_hour: Mapped[str | None] = mapped_column(String(13), nullable=True)  # YYYY-MM-DDTHH

    # Флаг блокировки (на случай злоупотреблений)
    is_blocked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Метаданные
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    # Связи
    user: Mapped["User | None"] = relationship(back_populates="devices")

    def __repr__(self) -> str:
        return f"<Device id={self.id} device_id={self.device_id!r} user_id={self.user_id}>"


# ── MagicCode ────────────────────────────────────────────────────

class MagicCode(Base):
    """PIN-код для авторизации по Magic Link.

    6-значный код, TTL 15 минут, одноразовый.
    """
    __tablename__ = "magic_codes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    code: Mapped[str] = mapped_column(String(6), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


# ── Category ─────────────────────────────────────────────────────

class Category(Base):
    """Категория транзакций — зеркало iOS CategoryModel.

    Поддерживает иерархию (parent_id) и soft delete (deleted_at).
    """
    __tablename__ = "categories"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    client_id: Mapped[str | None] = mapped_column(String(36), unique=True, nullable=True, index=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    parent_id: Mapped[int | None] = mapped_column(
        ForeignKey("categories.id", ondelete="CASCADE"), nullable=True
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    type: Mapped[str] = mapped_column(String(20), nullable=False)  # income | expense
    icon: Mapped[str | None] = mapped_column(String(8), nullable=True)
    ai_hint: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Связи
    user: Mapped["User"] = relationship(back_populates="categories")
    transactions: Mapped[list["Transaction"]] = relationship(back_populates="category")
    parent: Mapped["Category | None"] = relationship(
        "Category", remote_side=[id], back_populates="children"
    )
    children: Mapped[list["Category"]] = relationship(
        "Category", back_populates="parent", cascade="all, delete-orphan"
    )

    def __repr__(self) -> str:
        return f"<Category id={self.id} name={self.name!r} type={self.type}>"


# ── Transaction ──────────────────────────────────────────────────

class Transaction(Base):
    """Транзакция (доход/расход) — зеркало iOS TransactionModel.

    Суммы хранятся как Numeric(12,2) — PostgreSQL поддерживает Decimal нативно.
    """
    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    client_id: Mapped[str | None] = mapped_column(String(36), unique=True, nullable=True, index=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    category_id: Mapped[int | None] = mapped_column(
        ForeignKey("categories.id", ondelete="SET NULL"), nullable=True
    )
    type: Mapped[str] = mapped_column(String(20), nullable=False)  # income | expense
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(10), default="RUB", nullable=False)
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    transaction_date: Mapped[date] = mapped_column(Date, nullable=False)
    attachment_path: Mapped[str | None] = mapped_column(String(500), nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Связи
    user: Mapped["User"] = relationship(back_populates="transactions")
    category: Mapped["Category | None"] = relationship(back_populates="transactions")

    def __repr__(self) -> str:
        return f"<Transaction id={self.id} type={self.type} amount={self.amount}>"


# ── Counterpart ──────────────────────────────────────────────────

class Counterpart(Base):
    """Контрагент (субъект) — зеркало iOS CounterpartModel.

    Кому дали/взяли в долг, от кого получили доход и т.д.
    """
    __tablename__ = "counterparts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    client_id: Mapped[str | None] = mapped_column(String(36), unique=True, nullable=True, index=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    icon: Mapped[str | None] = mapped_column(String(8), nullable=True)
    ai_hint: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Связи
    user: Mapped["User"] = relationship(back_populates="counterparts")
    debts: Mapped[list["Debt"]] = relationship(back_populates="counterpart")

    def __repr__(self) -> str:
        return f"<Counterpart id={self.id} name={self.name!r}>"


# ── Debt ─────────────────────────────────────────────────────────

class Debt(Base):
    """Долг — зеркало iOS DebtModel.

    direction: 'gave' (я дал в долг) | 'took' (я взял в долг).
    """
    __tablename__ = "debts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    client_id: Mapped[str | None] = mapped_column(String(36), unique=True, nullable=True, index=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    counterpart_id: Mapped[int | None] = mapped_column(
        ForeignKey("counterparts.id", ondelete="SET NULL"), nullable=True
    )
    direction: Mapped[str] = mapped_column(String(10), nullable=False)  # gave | took
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    paid_amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=0, nullable=False)
    currency: Mapped[str] = mapped_column(String(10), default="RUB", nullable=False)
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    debt_date: Mapped[date] = mapped_column(Date, nullable=False)
    due_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    is_closed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Связи
    user: Mapped["User"] = relationship(back_populates="debts")
    counterpart: Mapped["Counterpart | None"] = relationship(back_populates="debts")
    payments: Mapped[list["DebtPayment"]] = relationship(back_populates="debt", cascade="all, delete-orphan")

    def __repr__(self) -> str:
        return f"<Debt id={self.id} direction={self.direction} amount={self.amount}>"


# ── DebtPayment ──────────────────────────────────────────────────

class DebtPayment(Base):
    """Платёж по долгу — зеркало iOS DebtPaymentModel."""
    __tablename__ = "debt_payments"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    client_id: Mapped[str | None] = mapped_column(String(36), unique=True, nullable=True, index=True)
    debt_id: Mapped[int] = mapped_column(
        ForeignKey("debts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    payment_date: Mapped[date] = mapped_column(Date, nullable=False)
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Связи
    debt: Mapped["Debt"] = relationship(back_populates="payments")

    def __repr__(self) -> str:
        return f"<DebtPayment id={self.id} debt_id={self.debt_id} amount={self.amount}>"


# ── UserSettings ─────────────────────────────────────────────────

class UserSettings(Base):
    """Настройки пользователя — хранятся на сервере для синхронизации между устройствами."""
    __tablename__ = "user_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False
    )

    # Синхронизация
    sync_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Валюта и тема
    default_currency: Mapped[str] = mapped_column(String(10), default="RUB", nullable=False)
    theme: Mapped[str] = mapped_column(String(10), default="dark", nullable=False)

    # AI кастомный промпт
    custom_prompt: Mapped[str | None] = mapped_column(Text, nullable=True)

    # Связи
    user: Mapped["User"] = relationship(back_populates="settings")

    def __repr__(self) -> str:
        return f"<UserSettings id={self.id} user_id={self.user_id} sync={self.sync_enabled}>"
