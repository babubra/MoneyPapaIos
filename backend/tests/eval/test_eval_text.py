"""Параметризованный runner для мок-эвалов (regression нашего обработчика)."""

import pytest

from app.api.v1.ai import _call_ai_text
from app.core.system_prompt import build_ai_prompt
from tests.conftest import make_response
from tests.eval.cases import CASES


def _pytest_id(case: dict) -> str:
    return case["id"]


@pytest.mark.parametrize("case", CASES, ids=_pytest_id)
async def test_mock_eval(case, mock_ai_client, request):
    if case.get("xfail_reason"):
        request.node.add_marker(pytest.mark.xfail(reason=case["xfail_reason"]))

    mock_ai_client.chat.completions.create.return_value = make_response(case["mock_response"])

    user_prompt = build_ai_prompt(
        user_text=case["text"],
        categories=case.get("categories", []),
        counterparts=case.get("counterparts", []),
        today="2026-05-11",
        locale=case.get("locale", "ru"),
        mappings=case.get("mappings"),
    )

    result = await _call_ai_text(mock_ai_client, user_prompt, user_id=1)

    for key, expected in case["expected_subset"].items():
        actual = result.get(key)
        assert actual == expected, (
            f"[{case['id']}] поле {key!r}: ожидали {expected!r}, получили {actual!r}"
        )
