"""Параметризованный runner golden-кейсов — реальный вызов aitunnel.ru."""

import pytest

from app.api.v1.ai import _call_ai_text
from app.core.system_prompt import build_ai_prompt
from tests.golden.cases import GOLDEN_CASES


def _pytest_id(case: dict) -> str:
    return case["id"]


@pytest.mark.golden
@pytest.mark.parametrize("case", GOLDEN_CASES, ids=_pytest_id)
async def test_golden(case, real_ai_client, request):
    if case.get("xfail_reason"):
        request.node.add_marker(pytest.mark.xfail(reason=case["xfail_reason"]))

    user_prompt = build_ai_prompt(
        user_text=case["text"],
        categories=case.get("categories", []),
        counterparts=case.get("counterparts", []),
        today=case.get("today", "2026-05-11"),
        locale=case["locale"],
        mappings=case.get("mappings"),
    )

    result = await _call_ai_text(real_ai_client, user_prompt, user_id=0)

    # Жёсткие проверки
    for key, expected in case.get("assert_equals", {}).items():
        actual = result.get(key)
        assert actual == expected, (
            f"[{case['id']}] {key}: got {actual!r}, want {expected!r}. Full result: {result}"
        )

    # Мягкие проверки (значение из множества)
    for key, allowed in case.get("assert_in", {}).items():
        actual = result.get(key)
        assert actual in allowed, (
            f"[{case['id']}] {key}: got {actual!r}, want one of {allowed!r}. Full result: {result}"
        )

    # Проверки присутствия (поле должно быть непустым)
    for key in case.get("assert_present", []):
        actual = result.get(key)
        assert actual not in (None, "", "null"), (
            f"[{case['id']}] {key} must be non-empty, got {actual!r}. Full result: {result}"
        )

