"""Юнит-тесты для build_ai_prompt — формирование user-промпта для Gemini."""

import pytest

from app.core.system_prompt import _LOCALE_MAP, build_ai_prompt


def test_minimal_shape_has_required_markers():
    """Базовая структура промпта содержит все опорные маркеры."""
    prompt = build_ai_prompt(
        user_text="купил хлеб 100",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        locale="ru",
    )
    assert "Today's date: 2026-05-11" in prompt
    assert "Target locale for translations: русский" in prompt
    assert "## User Categories" in prompt
    assert "## User Counterparts" in prompt
    assert "## Transaction Text to Parse" in prompt
    assert "купил хлеб 100" in prompt


def test_en_locale_translated_in_prompt():
    prompt = build_ai_prompt(
        user_text="coffee 5",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        locale="en",
    )
    assert "Target locale for translations: English" in prompt


def test_categories_rendered_with_id_and_type():
    prompt = build_ai_prompt(
        user_text="купил хлеб",
        categories=[
            {"id": "c1", "name": "Продукты", "type": "expense"},
            {"id": "c2", "name": "Зарплата", "type": "income"},
        ],
        counterparts=[],
        today="2026-05-11",
    )
    assert 'id=c1, name="Продукты", type=expense' in prompt
    assert 'id=c2, name="Зарплата", type=income' in prompt


def test_empty_categories_render_placeholder():
    prompt = build_ai_prompt(
        user_text="X",
        categories=[],
        counterparts=[],
        today="2026-05-11",
    )
    assert "No categories yet." in prompt


def test_counterparts_rendered():
    prompt = build_ai_prompt(
        user_text="дал Сергею 1000",
        categories=[],
        counterparts=[{"id": "u1", "name": "Сергей Иванов"}],
        today="2026-05-11",
    )
    assert 'id=u1, name="Сергей Иванов"' in prompt


def test_mappings_none_skips_block():
    prompt = build_ai_prompt(
        user_text="X",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        mappings=None,
    )
    assert "User Category Preferences" not in prompt


def test_mappings_present_includes_block():
    prompt = build_ai_prompt(
        user_text="X",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        mappings=[
            {"item_phrase": "хлеб", "category_name": "Продукты", "weight": 3},
        ],
    )
    assert "User Category Preferences" in prompt
    assert '"хлеб" → "Продукты" (confidence: 3)' in prompt


def test_custom_prompt_section():
    prompt = build_ai_prompt(
        user_text="X",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        custom_prompt="Любые покупки в Wildberries — категория 'Одежда'.",
    )
    assert "## User Custom Instructions" in prompt
    assert "Wildberries" in prompt


def test_locale_map_covers_documented_locales():
    """_LOCALE_MAP покрывает все 12 локалей, заявленных в SYSTEM_PROMPT раздел 9."""
    expected = {"ru", "en", "de", "fr", "es", "it", "pt", "tr", "zh", "ja", "ko", "ar"}
    assert expected.issubset(set(_LOCALE_MAP.keys()))


@pytest.mark.xfail(
    reason="C2.21 — неизвестная локаль попадает в промпт сырой строкой. "
    "Закроется добавлением pattern в ParseTextRequest.locale."
)
def test_unknown_locale_does_not_leak_raw_code():
    """Если клиент прислал 'xx' (или опечатку), сырой код локали не должен
    попасть в промпт. Сейчас попадает — это red-test для finding #21."""
    prompt = build_ai_prompt(
        user_text="X",
        categories=[],
        counterparts=[],
        today="2026-05-11",
        locale="xx",
    )
    assert "Target locale for translations: xx" not in prompt
