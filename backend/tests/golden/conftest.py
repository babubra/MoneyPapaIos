"""Фикстуры для golden-сьюита — реальные вызовы aitunnel.ru."""

import os

import pytest
import pytest_asyncio
from openai import AsyncOpenAI

from app.core.config import get_settings


@pytest.fixture
def aitunnel_key_or_skip():
    """Skip golden-кейсов, если ключ не задан."""
    key = os.environ.get("AITUNNEL_API_KEY") or get_settings().AITUNNEL_API_KEY
    if not key:
        pytest.skip("AITUNNEL_API_KEY не задан — golden-сьюит пропущен")
    return key


@pytest_asyncio.fixture
async def real_ai_client(aitunnel_key_or_skip):
    """Реальный AsyncOpenAI-клиент для golden-кейсов.

    Function-scope: новый клиент на каждый тест. Для 15 тестов оверхед
    создания TCP-pool минимальный (httpx ленив до первого вызова),
    но мы избегаем ScopeMismatch с function-scope event_loop pytest-asyncio.

    `timeout=30` — explicit, чтобы зависший aitunnel не превращался
    в 10-минутное молчание (SDK default — 600s).
    """
    settings = get_settings()
    client = AsyncOpenAI(
        api_key=aitunnel_key_or_skip,
        base_url=settings.AITUNNEL_BASE_URL,
        timeout=30.0,
    )
    try:
        yield client
    finally:
        await client.close()
