"""Юнит-тесты для _normalize_null_strings — приводим строки 'null'/'None'/'' к настоящему None
в whitelisted-полях ответа AI."""

import pytest

from app.api.v1.ai import _normalize_null_strings, _NULLABLE_FIELDS


@pytest.mark.parametrize("bad_value", ["null", "None", "", "  null  ", "NULL", "none"])
def test_string_null_becomes_none_in_whitelisted_field(bad_value):
    data = {"category_id": bad_value, "amount": 100}
    out = _normalize_null_strings(data)
    assert out["category_id"] is None
    assert out["amount"] == 100  # числа не трогаем


def test_real_none_stays_none():
    data = {"category_id": None}
    out = _normalize_null_strings(data)
    assert out["category_id"] is None


def test_non_whitelisted_string_not_touched():
    """Поле, отсутствующее в _NULLABLE_FIELDS, не нормализуется — даже если оно 'null'."""
    data = {"some_random_field": "null"}
    out = _normalize_null_strings(data)
    assert out["some_random_field"] == "null"


def test_non_dict_input_passes_through():
    assert _normalize_null_strings("not a dict") == "not a dict"
    assert _normalize_null_strings(None) is None
    assert _normalize_null_strings([1, 2, 3]) == [1, 2, 3]


def test_all_whitelisted_fields_normalize():
    """Каждое поле из _NULLABLE_FIELDS должно нормализоваться от строки 'null'."""
    data = {field: "null" for field in _NULLABLE_FIELDS}
    out = _normalize_null_strings(data)
    for field in _NULLABLE_FIELDS:
        assert out[field] is None, f"Поле {field} не нормализовалось"


def test_real_values_in_whitelisted_fields_preserved():
    """Реальные значения (не 'null'-строки) не должны быть тронуты."""
    data = {
        "type": "expense",
        "amount": "100",  # строковое число — НЕ null-маркер
        "category_id": "uuid-123",
        "currency": "RUB",
    }
    out = _normalize_null_strings(data)
    assert out["type"] == "expense"
    assert out["amount"] == "100"
    assert out["category_id"] == "uuid-123"
    assert out["currency"] == "RUB"
