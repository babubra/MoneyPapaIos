"""Subscription API — статус подписки + StoreKit-заглушки.

Эндпоинты:
  • GET  /api/v1/subscription/status   — текущий статус подписки + AI trial counter (реальный)
  • POST /api/v1/subscription/verify   — верификация receipt (DEV-stub: ставит active на 30д)
  • POST /api/v1/subscription/webhook  — App Store Server Notifications V2 (заглушка)

TODO для production:
  1. /verify должен валидировать `receipt_data` через App Store Server API
     (https://developer.apple.com/documentation/appstoreserverapi). Сейчас
     эта заглушка просто верит клиенту — годится только для DEV_MODE и
     первоначального тестирования paywall-флоу.
  2. /webhook должен валидировать signed JWS payload от Apple
     (https://developer.apple.com/documentation/appstoreservernotifications).
     Сейчас эта заглушка только логирует и возвращает 200.
  3. Apple Sign-In revocation webhook (когда юзер отзывает SiwA из Settings →
     Apple ID) — отдельная задача.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Request, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.core.config import get_settings
from app.db.models import User
from app.db.session import get_db

logger = logging.getLogger(__name__)
router = APIRouter()
settings = get_settings()


# ── Pydantic схемы ─────────────────────────────────────────────────


class SubscriptionStatusResponse(BaseModel):
    """Текущий статус подписки + AI trial."""
    subscription_status: str = Field(..., description="free|active|expired|cancelled")
    subscription_expires_at: datetime | None = None
    subscription_product_id: str | None = None
    ai_trial_used: int
    ai_trial_limit: int


class VerifyReceiptRequest(BaseModel):
    """Запрос на верификацию receipt'а из StoreKit (DEV-stub)."""
    receipt_data: str = Field(..., min_length=1, description="signed JWS payload или DEV_STUB")
    product_id: str = Field(..., min_length=1, max_length=100)
    original_transaction_id: str | None = Field(default=None, max_length=100)


class VerifyReceiptResponse(BaseModel):
    """Ответ после верификации — обновлённый статус."""
    subscription_status: str
    subscription_expires_at: datetime | None
    subscription_product_id: str | None
    is_stub: bool = Field(default=False, description="True если verify прошёл через DEV-stub")


# ── Endpoints ──────────────────────────────────────────────────────


@router.get(
    "/status",
    response_model=SubscriptionStatusResponse,
    summary="Текущий статус подписки",
)
async def subscription_status(user: User = Depends(require_user)) -> SubscriptionStatusResponse:
    """Возвращает реальный статус подписки и AI trial counter."""
    return SubscriptionStatusResponse(
        subscription_status=user.subscription_status,
        subscription_expires_at=user.subscription_expires_at,
        subscription_product_id=user.subscription_product_id,
        ai_trial_used=user.ai_trial_used,
        ai_trial_limit=settings.AI_TRIAL_LIMIT,
    )


@router.post(
    "/verify",
    response_model=VerifyReceiptResponse,
    summary="Верификация receipt'а (DEV-stub)",
)
async def verify_receipt(
    body: VerifyReceiptRequest,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
) -> VerifyReceiptResponse:
    """DEV-stub: ставит subscription_status=active на 30 дней.

    TODO: заменить на реальную проверку через App Store Server API.
    Сейчас принимаем любой receipt_data (включая литерал "DEV_STUB") и
    ставим юзера в active. Это нужно, чтобы можно было разработать и
    протестировать iOS paywall до получения Apple Developer Program.
    """
    is_stub = True  # текущая реализация — заглушка
    expires_at = datetime.now(timezone.utc) + timedelta(days=30)

    user.subscription_status = "active"
    user.subscription_expires_at = expires_at
    user.subscription_product_id = body.product_id
    if body.original_transaction_id:
        user.subscription_original_transaction_id = body.original_transaction_id
    await db.flush()

    logger.warning(
        "DEV-STUB /subscription/verify: user_id=%s product=%s expires_at=%s",
        user.id, body.product_id, expires_at.isoformat(),
    )

    return VerifyReceiptResponse(
        subscription_status=user.subscription_status,
        subscription_expires_at=user.subscription_expires_at,
        subscription_product_id=user.subscription_product_id,
        is_stub=is_stub,
    )


@router.post(
    "/webhook",
    summary="App Store Server Notifications V2 (заглушка)",
    status_code=status.HTTP_200_OK,
)
async def app_store_webhook(request: Request) -> dict:
    """Принимает webhook от Apple, логирует payload, возвращает 200.

    TODO для production:
      1. Валидировать `signedPayload` (JWS) через Apple JWKS.
      2. Парсить notificationType (SUBSCRIBED / DID_RENEW / EXPIRED / REFUND / REVOKE).
      3. Находить юзера по originalTransactionId.
      4. Обновлять subscription_status / subscription_expires_at.
      5. Идемпотентность: дедуп по notificationUUID.
    """
    try:
        payload = await request.json()
    except Exception:
        payload = None
    logger.warning(
        "App Store webhook STUB: получен payload=%s (НЕ обработан, нужна реальная реализация)",
        payload,
    )
    return {"ok": True, "stub": True}
