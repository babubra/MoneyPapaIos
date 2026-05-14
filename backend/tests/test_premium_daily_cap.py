"""Тесты Premium daily-cap gate (#15 в audit/C1_C2_ai_layer.md).

Покрывают _check_trial и _consume_trial для Premium-веток:
- Premium до cap — пропускается.
- Premium на cap — 429.
- Раздельные счётчики для текста и аудио.
- Reset на наступление новых UTC-суток.
- Истёкшая подписка → fallback на free trial logic.

Free-ветка покрыта существующими тестами в test_call_ai_text.py (косвенно)
и здесь дополнительно — для regression-сравнения с Premium-веткой.
"""

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from app.api.v1.ai import (
    _check_trial,
    _consume_trial,
    _reset_premium_counters_if_needed,
    _utc_today_str,
)
from app.core.config import get_settings

settings = get_settings()


# ── Helpers ────────────────────────────────────────────────────────────


def make_user(
    *,
    premium: bool,
    ai_trial_used: int = 0,
    ai_requests_today: int = 0,
    ai_audio_requests_today: int = 0,
    ai_requests_reset_date: str | None = None,
    expires_in_days: int | None = 30,  # None = бессрочно
):
    """Минимальный User-stub. SimpleNamespace позволяет мутировать поля как
    SQLAlchemy-модель, без таскать через ORM-сессию."""
    if premium:
        status = "active"
        expires_at = (
            None
            if expires_in_days is None
            else datetime.now(timezone.utc) + timedelta(days=expires_in_days)
        )
    else:
        status = "free"
        expires_at = None
    return SimpleNamespace(
        ai_trial_used=ai_trial_used,
        subscription_status=status,
        subscription_expires_at=expires_at,
        ai_requests_today=ai_requests_today,
        ai_audio_requests_today=ai_audio_requests_today,
        ai_requests_reset_date=ai_requests_reset_date or _utc_today_str(),
    )


def make_db():
    """AsyncSession-double: интересует только flush()."""
    db = AsyncMock()
    db.flush = AsyncMock()
    return db


# ── Reset-логика (helper отдельно) ─────────────────────────────────────


def test_reset_helper_zeroes_counters_on_new_day():
    user = make_user(
        premium=True,
        ai_requests_today=42,
        ai_audio_requests_today=7,
        ai_requests_reset_date="1999-01-01",
    )

    _reset_premium_counters_if_needed(user)

    assert user.ai_requests_today == 0
    assert user.ai_audio_requests_today == 0
    assert user.ai_requests_reset_date == _utc_today_str()


def test_reset_helper_noop_when_same_day():
    today = _utc_today_str()
    user = make_user(
        premium=True,
        ai_requests_today=42,
        ai_audio_requests_today=7,
        ai_requests_reset_date=today,
    )

    _reset_premium_counters_if_needed(user)

    assert user.ai_requests_today == 42
    assert user.ai_audio_requests_today == 7


# ── Free-юзеры: trial-ветка (regression на существующее поведение) ─────


async def test_free_user_under_trial_limit_passes():
    user = make_user(premium=False, ai_trial_used=10)
    db = make_db()

    await _check_trial(user, db, is_audio=False)  # не бросает


async def test_free_user_at_trial_limit_blocked_402():
    user = make_user(premium=False, ai_trial_used=settings.AI_TRIAL_LIMIT)
    db = make_db()

    with pytest.raises(HTTPException) as exc:
        await _check_trial(user, db, is_audio=False)
    assert exc.value.status_code == 402


async def test_free_consume_increments_lifetime_trial():
    user = make_user(premium=False, ai_trial_used=5)
    db = make_db()

    await _consume_trial(user, db, is_audio=False)

    assert user.ai_trial_used == 6
    # Premium-счётчики не задеты у free-юзера.
    assert user.ai_requests_today == 0
    assert user.ai_audio_requests_today == 0


# ── Premium: text-ветка ────────────────────────────────────────────────


async def test_premium_text_under_cap_passes():
    user = make_user(premium=True, ai_requests_today=10)
    db = make_db()

    await _check_trial(user, db, is_audio=False)


async def test_premium_text_at_cap_blocked_429():
    user = make_user(
        premium=True, ai_requests_today=settings.AI_PREMIUM_DAILY_CAP_TEXT
    )
    db = make_db()

    with pytest.raises(HTTPException) as exc:
        await _check_trial(user, db, is_audio=False)
    assert exc.value.status_code == 429
    assert exc.value.headers["X-AI-Daily-Kind"] == "text"


async def test_premium_text_consume_increments_only_text():
    user = make_user(premium=True, ai_requests_today=10, ai_audio_requests_today=3)
    db = make_db()

    await _consume_trial(user, db, is_audio=False)

    assert user.ai_requests_today == 11
    assert user.ai_audio_requests_today == 3
    assert user.ai_trial_used == 0  # Free-счётчик не задет.


# ── Premium: audio-ветка ──────────────────────────────────────────────


async def test_premium_audio_under_cap_passes():
    user = make_user(premium=True, ai_audio_requests_today=5)
    db = make_db()

    await _check_trial(user, db, is_audio=True)


async def test_premium_audio_at_cap_blocked_429():
    user = make_user(
        premium=True, ai_audio_requests_today=settings.AI_PREMIUM_DAILY_CAP_AUDIO
    )
    db = make_db()

    with pytest.raises(HTTPException) as exc:
        await _check_trial(user, db, is_audio=True)
    assert exc.value.status_code == 429
    assert exc.value.headers["X-AI-Daily-Kind"] == "audio"


async def test_premium_audio_consume_increments_only_audio():
    user = make_user(premium=True, ai_requests_today=10, ai_audio_requests_today=3)
    db = make_db()

    await _consume_trial(user, db, is_audio=True)

    assert user.ai_audio_requests_today == 4
    assert user.ai_requests_today == 10  # Text counter не задет.


# ── Кросс-проверка: text-cap не блокирует audio и наоборот ─────────────


async def test_text_cap_doesnt_block_audio():
    user = make_user(
        premium=True,
        ai_requests_today=settings.AI_PREMIUM_DAILY_CAP_TEXT,  # text cap exhausted
        ai_audio_requests_today=0,
    )
    db = make_db()

    await _check_trial(user, db, is_audio=True)  # audio проходит


async def test_audio_cap_doesnt_block_text():
    user = make_user(
        premium=True,
        ai_requests_today=0,
        ai_audio_requests_today=settings.AI_PREMIUM_DAILY_CAP_AUDIO,
    )
    db = make_db()

    await _check_trial(user, db, is_audio=False)  # text проходит


# ── Auto-reset на наступление новых UTC-суток ──────────────────────────


async def test_premium_check_resets_counter_on_new_day():
    """Юзер был на cap'е во вчерашних счётчиках — на новой дате _check_trial
    обнуляет и пропускает."""
    user = make_user(
        premium=True,
        ai_requests_today=settings.AI_PREMIUM_DAILY_CAP_TEXT,
        ai_requests_reset_date="1999-01-01",  # «вчера и раньше»
    )
    db = make_db()

    await _check_trial(user, db, is_audio=False)  # не бросает

    assert user.ai_requests_today == 0
    assert user.ai_requests_reset_date == _utc_today_str()


async def test_premium_consume_resets_then_increments_on_new_day():
    user = make_user(
        premium=True,
        ai_requests_today=199,
        ai_audio_requests_today=49,
        ai_requests_reset_date="1999-01-01",
    )
    db = make_db()

    await _consume_trial(user, db, is_audio=False)

    # Reset обнулил оба, потом инкрементнул text.
    assert user.ai_requests_today == 1
    assert user.ai_audio_requests_today == 0
    assert user.ai_requests_reset_date == _utc_today_str()


# ── Истекшая Premium-подписка → fallback на free-логику ────────────────


async def test_expired_premium_falls_back_to_free_trial():
    """subscription_status=active, но expires_at < now → НЕ premium →
    проверяется ai_trial_used вместо daily-cap."""
    user = make_user(
        premium=True,
        ai_trial_used=settings.AI_TRIAL_LIMIT,
        # Перетираем expires_at в прошлое.
        expires_in_days=-1,
    )
    db = make_db()

    with pytest.raises(HTTPException) as exc:
        await _check_trial(user, db, is_audio=False)
    # 402, как для обычного free-юзера на лимите.
    assert exc.value.status_code == 402


async def test_premium_without_expiry_is_perpetual():
    """expires_at=NULL трактуется как бессрочный Premium (внутреннее тестирование)."""
    user = make_user(premium=True, expires_in_days=None, ai_requests_today=10)
    db = make_db()

    await _check_trial(user, db, is_audio=False)  # проходит, не бросает


# ── 402 не выскакивает для Premium с исчерпанным trial ─────────────────


async def test_premium_with_high_trial_still_uses_premium_path():
    """Премиум-юзер с ai_trial_used=999 (история до подписки) должен
    идти по daily-cap пути, не по 402-пути."""
    user = make_user(premium=True, ai_trial_used=9999, ai_requests_today=10)
    db = make_db()

    await _check_trial(user, db, is_audio=False)  # проходит
