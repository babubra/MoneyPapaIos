"""Тесты для in-memory TTL-стора идемпотентности (#3 в audit/C1_C2_ai_layer.md).

Стор живёт в `app.core.idempotency` и используется через FastAPI-dependency
в /parse и /parse-audio. На этом слое — чистый unit-тест на сам стор:
поведение acquire / commit / release_failure / TTL-expiry / concurrency.
"""

import asyncio
import time

import pytest

from app.core.idempotency import IdempotencyState, IdempotencyStore


# ── Базовые состояния ──────────────────────────────────────────────────


async def test_new_key_returns_new_state():
    """Первый acquire с новым ключом — стор отдаёт 'new' и in-flight Event."""
    store = IdempotencyStore(ttl_seconds=60)

    state, payload = await store.acquire("u1:key1")

    assert state is IdempotencyState.NEW
    assert isinstance(payload, asyncio.Event)
    assert not payload.is_set()


async def test_in_flight_second_acquire_returns_conflict():
    """Второй acquire с тем же ключом, пока первый ещё в обработке → CONFLICT."""
    store = IdempotencyStore(ttl_seconds=60)

    await store.acquire("u1:key1")
    state, payload = await store.acquire("u1:key1")

    assert state is IdempotencyState.IN_FLIGHT
    # Payload — это Event первого вызова, чтобы клиент мог дождаться (но мы 409'им).
    assert isinstance(payload, asyncio.Event)


async def test_commit_then_acquire_returns_cached():
    """После commit'а тот же ключ возвращает закэшированный результат."""
    store = IdempotencyStore(ttl_seconds=60)
    await store.acquire("u1:key1")

    result = {"status": "ok", "type": "expense", "amount": 100}
    await store.commit("u1:key1", result)

    state, payload = await store.acquire("u1:key1")
    assert state is IdempotencyState.CACHED
    assert payload == result


# ── Release / failure ──────────────────────────────────────────────────


async def test_release_failure_lets_retry_succeed():
    """AI упал → release → новый acquire с тем же ключом снова получает NEW."""
    store = IdempotencyStore(ttl_seconds=60)
    await store.acquire("u1:key1")

    await store.release_failure("u1:key1")

    state, _ = await store.acquire("u1:key1")
    assert state is IdempotencyState.NEW, (
        "После release_failure ключ должен быть свободен — иначе фейл блокирует "
        "юзера на ttl_seconds, что хуже, чем дать ему ретраить вручную."
    )


async def test_release_failure_idempotent():
    """release_failure на уже отпущенный или несуществующий ключ — no-op, не падает."""
    store = IdempotencyStore(ttl_seconds=60)
    await store.release_failure("nonexistent")  # просто не должно бросить
    await store.acquire("u1:key1")
    await store.release_failure("u1:key1")
    await store.release_failure("u1:key1")  # двойной release — тоже OK


# ── TTL-expiry ─────────────────────────────────────────────────────────


async def test_cached_entry_expires_after_ttl():
    """Через ttl_seconds кэш истекает, следующий acquire — снова NEW."""
    store = IdempotencyStore(ttl_seconds=0.1)  # 100ms для быстрого теста

    await store.acquire("u1:key1")
    await store.commit("u1:key1", {"status": "ok"})

    # Сразу — CACHED
    state, _ = await store.acquire("u1:key1")
    assert state is IdempotencyState.CACHED

    # Подождём дольше TTL
    await asyncio.sleep(0.15)

    state, payload = await store.acquire("u1:key1")
    assert state is IdempotencyState.NEW
    assert isinstance(payload, asyncio.Event)


# ── Ключи разных юзеров ────────────────────────────────────────────────


async def test_different_users_independent_keys():
    """Один и тот же idempotency-key у двух разных user_id — независимые записи."""
    store = IdempotencyStore(ttl_seconds=60)

    state1, _ = await store.acquire("u1:samekey")
    state2, _ = await store.acquire("u2:samekey")

    assert state1 is IdempotencyState.NEW
    assert state2 is IdempotencyState.NEW

    await store.commit("u1:samekey", {"data": "user1"})
    # u2's запись осталась in-flight
    state2_again, payload2 = await store.acquire("u2:samekey")
    assert state2_again is IdempotencyState.IN_FLIGHT

    # u1's запись теперь CACHED
    state1_again, payload1 = await store.acquire("u1:samekey")
    assert state1_again is IdempotencyState.CACHED
    assert payload1 == {"data": "user1"}


# ── Concurrency ────────────────────────────────────────────────────────


async def test_concurrent_acquires_only_one_new():
    """При параллельных acquire'ах одного ключа только один получит NEW,
    все остальные — IN_FLIGHT. Защищает от lost-update."""
    store = IdempotencyStore(ttl_seconds=60)

    # 10 параллельных acquire'ов на один ключ
    results = await asyncio.gather(*[store.acquire("u1:race") for _ in range(10)])

    new_count = sum(1 for state, _ in results if state is IdempotencyState.NEW)
    in_flight_count = sum(1 for state, _ in results if state is IdempotencyState.IN_FLIGHT)

    assert new_count == 1, f"Ровно один acquire должен получить NEW, получено: {new_count}"
    assert in_flight_count == 9
