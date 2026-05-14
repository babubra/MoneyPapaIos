"""In-memory TTL-стор для идемпотентности AI-запросов (#3 в audit/C1_C2_ai_layer.md).

Назначение: при flaky-network клиент iOS делает retry с тем же `Idempotency-Key`.
Без идемпотентности это даёт двойной AI-charge и двойное списание trial. С ней —
второй запрос получает закэшированный ответ первого, AI вызывается ровно один раз.

Архитектура:
  • Ключ = "{user_id}:{idempotency_key}" (изоляция между юзерами).
  • Состояния: NEW (мы первые, можем работать), IN_FLIGHT (concurrent retry в полёте,
    клиент получает 409), CACHED (уже отработали, возвращаем сохранённый result).
  • TTL — 60s по умолчанию (см. settings). Достаточно для retry-окна iOS-клиента
    (max latency: 15s timeout + 1s + 3s + 15s ≈ 34s); юзеру за 60s ретапать другой
    запрос с тем же idempotency-key он не будет (UUID generation на user-action).
  • Storage: in-memory dict в `app.state.idempotency_store`. Не переживёт рестарт,
    но в 60s-окне это OK (рестарт = деплой, юзер ретапнет позже как новый запрос).
  • Concurrency: один asyncio.Lock на стор; критичная секция короткая (read/write
    одной записи), нет блокировок на длительность AI-вызова.

Не используется Redis/Postgres — overkill для 60s-окна и одного worker'а. Если
в будущем уйдём в multi-worker — заменим на распределённый стор (interface один).
"""

import asyncio
import enum
import time
from typing import Any


class IdempotencyState(enum.Enum):
    """Состояние ключа в сторе на момент acquire."""

    NEW = "new"          # Ключ не использовался — caller'у можно работать
    IN_FLIGHT = "in_flight"  # Кто-то уже работает — caller должен получить 409
    CACHED = "cached"    # Результат готов — возвращаем без повторного AI-вызова


class IdempotencyStore:
    """TTL-стор для пар (idempotency_key → result | in_flight_event).

    Stateful, держит запись TTL секунд после `commit`. После TTL запись стирается
    при следующем `acquire` того же ключа (lazy cleanup — нет фонового потока).
    """

    def __init__(self, ttl_seconds: float = 60.0) -> None:
        # _entries[key] = (expires_at_monotonic, payload_or_event)
        #   payload — dict с результатом если CACHED
        #   event — asyncio.Event если IN_FLIGHT (set() на commit/release)
        self._entries: dict[str, tuple[float, Any]] = {}
        self._ttl = ttl_seconds
        self._lock = asyncio.Lock()

    async def acquire(self, key: str) -> tuple[IdempotencyState, Any]:
        """Регистрирует попытку выполнить операцию для ключа.

        Возвращает:
          (NEW, asyncio.Event)      — caller'у можно выполнять, потом commit/release
          (IN_FLIGHT, asyncio.Event) — кто-то уже работает; caller возвращает 409
          (CACHED, result_dict)     — результат готов; caller возвращает его
        """
        now = time.monotonic()
        async with self._lock:
            entry = self._entries.get(key)
            if entry is not None:
                expires_at, payload = entry
                if expires_at <= now:
                    # Записи место — protokol: lazy cleanup
                    del self._entries[key]
                    entry = None

            if entry is None:
                event = asyncio.Event()
                # In-flight записи живут до commit/release или истечения ttl
                # (если worker умер и release не пришёл — запись провиснет на ttl
                # и затем lazy-cleanup'нется на следующем acquire). Это не идеально,
                # но соответствует UX: юзер ретапнет позже как новый запрос.
                self._entries[key] = (now + self._ttl, event)
                return IdempotencyState.NEW, event

            expires_at, payload = entry
            if isinstance(payload, asyncio.Event):
                return IdempotencyState.IN_FLIGHT, payload
            return IdempotencyState.CACHED, payload

    async def commit(self, key: str, result: dict) -> None:
        """Фиксирует успешный результат — IN_FLIGHT → CACHED.

        После commit'а acquire того же ключа в течение ttl_seconds вернёт CACHED.
        """
        now = time.monotonic()
        async with self._lock:
            entry = self._entries.get(key)
            event = entry[1] if entry and isinstance(entry[1], asyncio.Event) else None
            self._entries[key] = (now + self._ttl, result)
        # Сетим event ВНЕ lock'а — никто не ждёт на нём (мы возвращаем 409, а не блокируемся),
        # но ставим на всякий случай, если кто-то решит await'ить в будущем.
        if event is not None:
            event.set()

    async def release_failure(self, key: str) -> None:
        """Снимает IN_FLIGHT-запись (AI упал, юзер должен мочь ретраить).

        Иначе фейл одного AI-вызова блокировал бы юзера на ttl_seconds — хуже
        чем дать ему повторить попытку явно. No-op если ключа нет.
        """
        async with self._lock:
            entry = self._entries.pop(key, None)
        # Снимаем event'ы только если запись была IN_FLIGHT — иначе ничего не делаем
        if entry is not None and isinstance(entry[1], asyncio.Event):
            entry[1].set()
