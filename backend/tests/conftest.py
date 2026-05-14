"""Общие фикстуры для всех тестов backend/."""

import json
import os
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# ── Загрузка backend/.env до импорта app.* ───────────────────────────
# Pydantic-settings читает .env при инициализации Settings, но при этом
# os.environ имеет приоритет НАД .env. Любые setdefault'ы ниже сработают
# как «дефолт если переменной нигде нет» — потому что мы сперва вливаем
# .env в os.environ, а потом ставим fallback'и.
_env_path = Path(__file__).resolve().parent.parent / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        os.environ.setdefault(key, val)

# Fallback'и для fresh-clone / CI без .env. Реальные значения из .env
# уже в os.environ, поэтому setdefault их не тронет.
os.environ.setdefault("SECRET_KEY", "x" * 64)
os.environ.setdefault("AI_MODEL", "gemini-2.5-flash-lite")

import pytest  # noqa: E402
from openai import AsyncOpenAI  # noqa: E402


@pytest.fixture
def mock_ai_client():
    """AsyncOpenAI-double для мок-тестов. Метод create заменён на AsyncMock —
    тест задаёт side_effect / return_value по сценарию."""
    client = MagicMock(spec=AsyncOpenAI)
    client.chat = MagicMock()
    client.chat.completions = MagicMock()
    client.chat.completions.create = AsyncMock()
    return client


def make_response(
    content: str | dict,
    *,
    prompt_tokens: int = 100,
    completion_tokens: int = 50,
    cached_tokens: int = 0,
):
    """Собирает фейковый ChatCompletion-ответ под shape, который читает
    _call_ai_text / _log_ai_usage. content может быть строкой (как есть) или
    dict (auto-JSON)."""
    text = content if isinstance(content, str) else json.dumps(content)

    msg = MagicMock()
    msg.content = text
    choice = MagicMock()
    choice.message = msg

    usage = MagicMock()
    usage.prompt_tokens = prompt_tokens
    usage.completion_tokens = completion_tokens
    usage.total_tokens = prompt_tokens + completion_tokens
    details = MagicMock()
    details.cached_tokens = cached_tokens
    usage.prompt_tokens_details = details

    response = MagicMock()
    response.choices = [choice]
    response.usage = usage
    return response
