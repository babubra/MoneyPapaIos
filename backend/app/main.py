"""FastAPI приложение MonPapa Backend."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from openai import AsyncOpenAI

from app.core.config import get_settings
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

    yield  # приложение работает

    # ── Shutdown ───────────────────────────────────────────────────
    await app.state.ai_client.close()
    await engine.dispose()
    logger.info("Соединения закрыты, приложение остановлено")


app = FastAPI(
    title="MonPapa API",
    description="Backend для iOS-приложения MonPapa — учёт личных финансов с AI-вводом.",
    version="2.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=app_settings.cors_origins_list + ["*"],  # * убрать в prod
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Роутеры ───────────────────────────────────────────────────────

from app.api.v1 import auth, ai, categories, transactions, counterparts, debts, settings, sync  # noqa: E402

app.include_router(auth.router,          prefix="/api/v1/auth",          tags=["auth"])
app.include_router(ai.router,            prefix="/api/v1/ai",            tags=["ai"])
app.include_router(categories.router,    prefix="/api/v1/categories",    tags=["categories"])
app.include_router(transactions.router,  prefix="/api/v1/transactions",  tags=["transactions"])
app.include_router(counterparts.router,  prefix="/api/v1/counterparts",  tags=["counterparts"])
app.include_router(debts.router,         prefix="/api/v1/debts",         tags=["debts"])
app.include_router(settings.router,      prefix="/api/v1/settings",      tags=["settings"])
app.include_router(sync.router,          prefix="/api/v1/sync",          tags=["sync"])


# ── Health check ──────────────────────────────────────────────────

@app.get("/health", tags=["system"], summary="Проверка работоспособности")
async def health() -> dict:
    return {"status": "ok", "service": "monpapa-backend", "version": "2.0.0"}


@app.get("/", tags=["system"], include_in_schema=False)
async def root() -> dict:
    return {"message": "MonPapa API v2. Документация: /docs"}
