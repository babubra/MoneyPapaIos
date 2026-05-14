"""Мок-тесты для _call_ai_text — retry-логика, error handling, usage-логирование.

Сюда НЕ идут eval-кейсы качества модели (это tests/golden/). Здесь только
наш Python-обработчик: что мы делаем когда AI вернул мусор, упал, отдал
markdown-обёртку, etc.
"""

import json
import logging

import pytest
from fastapi import HTTPException
from openai import APIStatusError

from app.api.v1 import ai as ai_module
from app.api.v1.ai import _call_ai_text
from tests.conftest import make_response


# ── Happy path ────────────────────────────────────────────────────────


async def test_happy_path_returns_parsed_json(mock_ai_client):
    payload = {"status": "ok", "type": "expense", "amount": 100}
    mock_ai_client.chat.completions.create.return_value = make_response(payload)

    result = await _call_ai_text(mock_ai_client, "купил хлеб 100", user_id=42)

    assert result == payload
    assert mock_ai_client.chat.completions.create.call_count == 1


async def test_call_args_match_contract(mock_ai_client):
    """Гарантируем contract вызова: model, temperature=0, max_tokens=1024,
    response_format=json_object. Любая регрессия этих параметров — баг."""
    mock_ai_client.chat.completions.create.return_value = make_response(
        {"status": "ok", "type": "income", "amount": 1}
    )

    await _call_ai_text(mock_ai_client, "any", user_id=1)

    call = mock_ai_client.chat.completions.create.call_args
    kwargs = call.kwargs
    assert kwargs["temperature"] == 0
    assert kwargs["max_tokens"] == 1024
    assert kwargs["response_format"] == {"type": "json_object"}
    assert kwargs["model"] == ai_module.settings.AI_MODEL
    # SYSTEM первый, USER второй
    assert kwargs["messages"][0]["role"] == "system"
    assert kwargs["messages"][1]["role"] == "user"
    assert kwargs["messages"][1]["content"] == "any"


# ── Sanitize вытягивает плохой JSON без retry ─────────────────────────


async def test_markdown_wrapper_sanitized_without_retry(mock_ai_client):
    """Markdown-обёртка вытягивается _sanitize_json'ом на первой попытке."""
    raw = '```json\n{"status": "ok", "type": "expense", "amount": 50}\n```'
    mock_ai_client.chat.completions.create.return_value = make_response(raw)

    result = await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert result["amount"] == 50
    assert mock_ai_client.chat.completions.create.call_count == 1


async def test_trailing_comma_sanitized_without_retry(mock_ai_client):
    raw = '{"status": "ok", "type": "expense", "amount": 50,}'
    mock_ai_client.chat.completions.create.return_value = make_response(raw)

    result = await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert result["amount"] == 50
    assert mock_ai_client.chat.completions.create.call_count == 1


# ── Retry ──────────────────────────────────────────────────────────────


async def test_retry_on_unrecoverable_json_then_success(mock_ai_client):
    """Первая попытка возвращает мусор, который sanitize не спасёт.
    Вторая попытка возвращает чистый JSON. Итог = вторая попытка."""
    mock_ai_client.chat.completions.create.side_effect = [
        make_response("not even close to json {{{"),
        make_response({"status": "ok", "type": "income", "amount": 999}),
    ]

    result = await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert result["amount"] == 999
    assert mock_ai_client.chat.completions.create.call_count == 2


async def test_two_failures_raise_502(mock_ai_client):
    mock_ai_client.chat.completions.create.side_effect = [
        make_response("garbage 1"),
        make_response("garbage 2"),
    ]

    with pytest.raises(HTTPException) as ei:
        await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert ei.value.status_code == 502
    assert mock_ai_client.chat.completions.create.call_count == 2


# ── API errors ────────────────────────────────────────────────────────


async def test_api_status_error_maps_to_502(mock_ai_client):
    """APIStatusError от провайдера → 502 без retry."""
    req = object()
    resp = type("R", (), {"status_code": 500, "headers": {}, "request": req})()
    err = APIStatusError("upstream broke", response=resp, body=None)
    mock_ai_client.chat.completions.create.side_effect = err

    with pytest.raises(HTTPException) as ei:
        await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert ei.value.status_code == 502
    assert mock_ai_client.chat.completions.create.call_count == 1


async def test_missing_api_key_raises_503(mock_ai_client, monkeypatch):
    """Пустой AITUNNEL_API_KEY → 503 ДО вызова клиента."""
    monkeypatch.setattr(ai_module.settings, "AITUNNEL_API_KEY", "")

    with pytest.raises(HTTPException) as ei:
        await _call_ai_text(mock_ai_client, "x", user_id=1)
    assert ei.value.status_code == 503
    mock_ai_client.chat.completions.create.assert_not_called()


# ── Usage-логирование ────────────────────────────────────────────────


async def test_usage_logged_on_success(mock_ai_client, caplog):
    """_log_ai_usage пишет на INFO с полями prompt/completion/total/cached."""
    mock_ai_client.chat.completions.create.return_value = make_response(
        {"status": "ok", "type": "expense", "amount": 1},
        prompt_tokens=3000,
        completion_tokens=120,
        cached_tokens=0,
    )

    with caplog.at_level(logging.INFO, logger="app.api.v1.ai"):
        await _call_ai_text(mock_ai_client, "x", user_id=77)

    usage_records = [r for r in caplog.records if "AI usage" in r.getMessage()]
    assert len(usage_records) == 1
    msg = usage_records[0].getMessage()
    assert "mode=text" in msg
    assert "user_id=77" in msg
    assert "prompt=3000" in msg
    assert "completion=120" in msg
    assert "total=3120" in msg
    assert "cached=0" in msg


async def test_usage_logged_on_each_retry_attempt(mock_ai_client, caplog):
    """Каждая попытка — billable, лог пишется отдельно с attempt=N."""
    mock_ai_client.chat.completions.create.side_effect = [
        make_response("bad", prompt_tokens=100, completion_tokens=10),
        make_response({"status": "ok", "type": "income", "amount": 1},
                      prompt_tokens=100, completion_tokens=20),
    ]

    with caplog.at_level(logging.INFO, logger="app.api.v1.ai"):
        result = await _call_ai_text(mock_ai_client, "x", user_id=99)

    assert result["amount"] == 1
    usage_msgs = [r.getMessage() for r in caplog.records if "AI usage" in r.getMessage()]
    assert len(usage_msgs) == 2
    assert "attempt=2" in usage_msgs[1]
