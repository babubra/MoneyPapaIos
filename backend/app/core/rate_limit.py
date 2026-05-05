"""Простой in-memory IP rate-limiter.

Используется на чувствительных открытых эндпоинтах (Sign in with Apple, Magic Link request)
до того, как мы поднимем Redis-based решение. Не подходит для multi-worker окружения
с >1 инстансом backend'а — счётчик у каждого worker'а свой. Для текущей нагрузки и
single-host деплоя достаточно.

Ограничения:
  • Для prod c --workers 2 каждый воркер видит ~50% запросов, поэтому реальный лимит
    в N раз выше заданного (где N = число воркеров). Это compromise — заявленный
    лимит в коде остаётся консервативной верхней границей.
  • Если IP за прокси (nginx/Caddy) — нужен X-Forwarded-For с trust list. Сейчас
    мы доверяем uvicorn с --proxy-headers (см. docker-compose.prod.yml).

После того как поднимем Redis — заменить на slowapi или собственный Redis-counter.
"""

from __future__ import annotations

import logging
import time
from collections import defaultdict, deque
from threading import Lock

from fastapi import HTTPException, Request, status

logger = logging.getLogger(__name__)


class IPRateLimiter:
    """Sliding-window rate limit по IP.

    Хранит deque[timestamp] для каждого IP. На каждый ``check()`` чистим старые записи
    и проверяем длину окна.
    """

    def __init__(self, max_requests: int, window_seconds: int, name: str = "default") -> None:
        if max_requests <= 0 or window_seconds <= 0:
            raise ValueError("max_requests and window_seconds must be positive")
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.name = name
        self._buckets: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def _client_ip(self, request: Request) -> str:
        # uvicorn с --proxy-headers уже распарсил X-Forwarded-For в request.client.host.
        # Без --proxy-headers здесь будет адрес прокси, но он одинаковый для всех — это
        # деградирует rate-limit до глобального, что приемлемо как fallback.
        client = request.client
        return client.host if client else "unknown"

    def check(self, request: Request) -> None:
        """Бросает 429 если лимит превышен, иначе фиксирует попытку."""
        ip = self._client_ip(request)
        now = time.monotonic()
        cutoff = now - self.window_seconds

        with self._lock:
            bucket = self._buckets[ip]
            # Чистим устаревшие записи (slide window влево).
            while bucket and bucket[0] < cutoff:
                bucket.popleft()

            if len(bucket) >= self.max_requests:
                retry_after = max(1, int(bucket[0] + self.window_seconds - now) + 1)
                logger.warning(
                    "Rate-limit %s exceeded for ip=%s: %d/%d within %ds",
                    self.name, ip, len(bucket), self.max_requests, self.window_seconds,
                )
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=f"Слишком много попыток. Попробуйте через {retry_after} с.",
                    headers={"Retry-After": str(retry_after)},
                )

            bucket.append(now)


# ── Готовые лимитеры (singletons) ────────────────────────────────────
# Apple Sign-In — реже, чем magic-link, но всё равно открытый endpoint.
apple_signin_limiter = IPRateLimiter(max_requests=10, window_seconds=60, name="apple_signin")
# Magic Link request — спам почтовых ящиков. Узкий лимит.
magic_link_limiter = IPRateLimiter(max_requests=5, window_seconds=60, name="magic_link")
# PIN verify — защита от brute-force. 6 цифр = 1M вариантов; лимит = 10/мин с одного IP.
pin_verify_limiter = IPRateLimiter(max_requests=10, window_seconds=60, name="pin_verify")
