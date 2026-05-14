"""Тесты server-side валидации длительности аудио (#10 в audit/C1_C2_ai_layer.md).

Проверяют helper `_get_audio_duration_seconds` через мок `mutagen.File` —
без зависимостей от реальных audio-файлов в репо. Реальный m4a-флоу проверяется
curl-смоуком в README сессии.
"""

from types import SimpleNamespace
from unittest.mock import patch

import mutagen
import pytest
from fastapi import HTTPException

from app.api.v1.ai import _get_audio_duration_seconds


def _meta(length: float):
    """Имитирует mutagen.File-объект: только .info.length, как мы и используем."""
    return SimpleNamespace(info=SimpleNamespace(length=length))


# ── Нормальный путь ────────────────────────────────────────────────────


def test_returns_float_for_valid_audio():
    with patch("app.api.v1.ai.mutagen.File", return_value=_meta(12.5)):
        duration = _get_audio_duration_seconds(b"\x00\x00fake")
    assert duration == 12.5


def test_returns_exact_zero_boundary_rejected():
    """duration == 0 → 422. Граничный случай: даже валидный header может
    дать 0 если файл обрезан."""
    with patch("app.api.v1.ai.mutagen.File", return_value=_meta(0)):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00fake")
    assert exc.value.status_code == 422


def test_returns_negative_rejected():
    """duration < 0 защищаем тоже, на всякий случай если mutagen вернёт мусор."""
    with patch("app.api.v1.ai.mutagen.File", return_value=_meta(-1.0)):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00fake")
    assert exc.value.status_code == 422


# ── Невалидные файлы ──────────────────────────────────────────────────


def test_mutagen_returns_none_for_unknown_format():
    """mutagen.File() → None означает «формат не распознан»."""
    with patch("app.api.v1.ai.mutagen.File", return_value=None):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00fake")
    assert exc.value.status_code == 422


def test_meta_without_info_rejected():
    """mutagen может вернуть объект без `.info` — например, для очень битых файлов."""
    with patch("app.api.v1.ai.mutagen.File", return_value=SimpleNamespace(info=None)):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00fake")
    assert exc.value.status_code == 422


def test_mutagen_error_wrapped_into_422():
    """mutagen.MutagenError (битый header) → 422 с понятным detail."""
    def boom(*_args, **_kwargs):
        raise mutagen.MutagenError("malformed header")

    with patch("app.api.v1.ai.mutagen.File", side_effect=boom):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00not-an-audio")
    assert exc.value.status_code == 422
    assert "битый" in exc.value.detail.lower()


# ── Edge: length атрибута может не быть на старых версиях mutagen ──────


def test_missing_length_attribute_treated_as_zero():
    """Если mutagen вернул info без `.length` — getattr fallback на 0 → 422."""
    info_no_length = SimpleNamespace()  # нет атрибута length
    meta = SimpleNamespace(info=info_no_length)
    with patch("app.api.v1.ai.mutagen.File", return_value=meta):
        with pytest.raises(HTTPException) as exc:
            _get_audio_duration_seconds(b"\x00\x00fake")
    assert exc.value.status_code == 422
