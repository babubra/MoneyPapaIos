"""FastAPI приложение MonPapa Backend."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from openai import AsyncOpenAI

from app.core.config import get_settings
from app.core.idempotency import IdempotencyStore
from app.db.models import Base
from app.db.session import engine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger(__name__)
app_settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Управление жизненным циклом приложения.

    startup: инициализация БД + создание singleton AI-клиента.
    shutdown: корректное закрытие соединений.
    """
    # ── Startup ────────────────────────────────────────────────────
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("База данных инициализирована")

    app.state.ai_client = AsyncOpenAI(
        api_key=app_settings.AITUNNEL_API_KEY,
        base_url=app_settings.AITUNNEL_BASE_URL,
    )
    logger.info(f"AI-клиент инициализирован → {app_settings.AITUNNEL_BASE_URL}, модель: {app_settings.AI_MODEL}")

    # Idempotency-стор для дедупликации /parse и /parse-audio при retry на клиенте.
    # In-memory, ttl=60s — окно достаточно для max retry-latency iOS (~34s).
    app.state.idempotency_store = IdempotencyStore(ttl_seconds=app_settings.IDEMPOTENCY_TTL_SECONDS)
    logger.info(f"Idempotency-стор инициализирован → ttl={app_settings.IDEMPOTENCY_TTL_SECONDS}s")

    yield  # приложение работает

    # ── Shutdown ───────────────────────────────────────────────────
    await app.state.ai_client.close()
    await engine.dispose()
    logger.info("Соединения закрыты, приложение остановлено")


_docs_url = "/docs" if app_settings.DEV_MODE else None
_redoc_url = "/redoc" if app_settings.DEV_MODE else None
_openapi_url = "/openapi.json" if app_settings.DEV_MODE else None

app = FastAPI(
    title="MonPapa API",
    description="Backend для iOS-приложения MonPapa — учёт личных финансов с AI-вводом.",
    version="2.0.0",
    lifespan=lifespan,
    docs_url=_docs_url,
    redoc_url=_redoc_url,
    openapi_url=_openapi_url,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=app_settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Роутеры ───────────────────────────────────────────────────────

from app.api.v1 import (  # noqa: E402
    auth,
    ai,
    categories,
    transactions,
    counterparts,
    debts,
    settings,
    sync,
    subscription,
)

app.include_router(auth.router,          prefix="/api/v1/auth",          tags=["auth"])
app.include_router(ai.router,            prefix="/api/v1/ai",            tags=["ai"])
app.include_router(categories.router,    prefix="/api/v1/categories",    tags=["categories"])
app.include_router(transactions.router,  prefix="/api/v1/transactions",  tags=["transactions"])
app.include_router(counterparts.router,  prefix="/api/v1/counterparts",  tags=["counterparts"])
app.include_router(debts.router,         prefix="/api/v1/debts",         tags=["debts"])
app.include_router(settings.router,      prefix="/api/v1/settings",      tags=["settings"])
app.include_router(sync.router,          prefix="/api/v1/sync",          tags=["sync"])
app.include_router(subscription.router,  prefix="/api/v1/subscription",  tags=["subscription"])


# ── Health check ──────────────────────────────────────────────────

@app.get("/health", tags=["system"], summary="Проверка работоспособности")
async def health() -> dict:
    return {"status": "ok", "service": "monpapa-backend", "version": "2.0.0"}


@app.get("/", tags=["system"], include_in_schema=False)
async def root() -> dict:
    docs_hint = "Документация: /docs" if app_settings.DEV_MODE else "API v2"
    return {"message": f"MonPapa {docs_hint}"}
