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
settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Управление жизненным циклом приложения.

    startup: инициализация БД + создание singleton AI-клиента.
    shutdown: корректное закрытие соединений.
    """
    # ── Startup ────────────────────────────────────────────────────
    # Инициализируем БД
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("База данных инициализирована")

    # Создаём singleton AsyncOpenAI-клиент — один на всё приложение.
    # AsyncOpenAI использует httpx.AsyncClient внутри, который держит
    # пул соединений → эффективно при сотнях одновременных запросов.
    app.state.ai_client = AsyncOpenAI(
        api_key=settings.AITUNNEL_API_KEY,
        base_url=settings.AITUNNEL_BASE_URL,
    )
    logger.info(f"AI-клиент инициализирован → {settings.AITUNNEL_BASE_URL}, модель: {settings.AI_MODEL}")

    yield  # приложение работает

    # ── Shutdown ───────────────────────────────────────────────────
    await app.state.ai_client.close()
    await engine.dispose()
    logger.info("Соединения закрыты, приложение остановлено")


app = FastAPI(
    title="MonPapa API",
    description="Backend для iOS-приложения MonPapa — учёт личных финансов с AI-вводом.",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — разрешаем iOS (и потенциально web в будущем)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list + ["*"],  # * убрать в prod
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Роутеры (импорт после создания app чтобы избежать циклов) ─────

from app.api.v1 import auth, ai  # noqa: E402

app.include_router(auth.router, prefix="/api/v1/auth", tags=["auth"])
app.include_router(ai.router,   prefix="/api/v1/ai",   tags=["ai"])


# ── Health check ──────────────────────────────────────────────────

@app.get("/health", tags=["system"], summary="Проверка работоспособности")
async def health() -> dict:
    return {"status": "ok", "service": "monpapa-backend"}


@app.get("/", tags=["system"], include_in_schema=False)
async def root() -> dict:
    return {"message": "MonPapa API v1. Документация: /docs"}
