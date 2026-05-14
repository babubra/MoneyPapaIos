"""Юнит-тесты для _sanitize_json — очистка ответа AI от markdown / trailing commas / комментариев."""

import json

import pytest

from app.api.v1.ai import _sanitize_json


def test_plain_json_passthrough():
    src = '{"a": 1, "b": "x"}'
    assert _sanitize_json(src) == src


def test_strips_markdown_json_wrapper():
    src = '```json\n{"a": 1}\n```'
    assert _sanitize_json(src) == '{"a": 1}'


def test_strips_markdown_generic_wrapper():
    src = '```\n{"a": 1}\n```'
    assert _sanitize_json(src) == '{"a": 1}'


def test_strips_trailing_comma_in_object():
    src = '{"a": 1,}'
    assert _sanitize_json(src) == '{"a": 1}'


def test_strips_trailing_comma_in_array():
    src = '{"a": [1, 2, 3,]}'
    assert _sanitize_json(src) == '{"a": [1, 2, 3]}'


def test_strips_inline_comment():
    src = '{"a": 1} // tail'
    # после очистки результат должен быть распарсиваемым JSON
    parsed = json.loads(_sanitize_json(src))
    assert parsed == {"a": 1}


def test_combined_markdown_trailing_comma_and_comment():
    src = '```json\n{"a": 1, "b": 2,} // ok\n```'
    parsed = json.loads(_sanitize_json(src))
    assert parsed == {"a": 1, "b": 2}


def test_idempotent():
    """Двойной вызов даёт тот же результат — нет накопления артефактов очистки."""
    src = '```json\n{"a": 1,}\n```'
    once = _sanitize_json(src)
    twice = _sanitize_json(once)
    assert once == twice


@pytest.mark.xfail(
    reason="C2.19 — _sanitize_json обрезает '//' внутри значений (URL). "
    "Закроется в следующей сессии C1+C2-fixups."
)
def test_preserves_url_in_string_value():
    """URL внутри строкового значения JSON не должен страдать.

    Текущий regex `re.sub(r'//[^\\n]*', '', text)` режет всё после `//`,
    включая `https://example.com/pay`. Это red-test для finding #19 в
    todo/audit/C1_C2_ai_layer.md.
    """
    src = '{"raw_text": "https://example.com/pay"}'
    parsed = json.loads(_sanitize_json(src))
    assert parsed == {"raw_text": "https://example.com/pay"}
