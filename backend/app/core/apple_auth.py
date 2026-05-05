"""Sign in with Apple — server-side верификация identity_token.

Реализует REST-проверку identity_token, который iOS-клиент получает от
ASAuthorizationAppleIDProvider и пересылает на бэкенд:

1. Загружаем Apple JWKS (https://appleid.apple.com/auth/keys), кешируем в process memory.
2. Извлекаем `kid` из header токена → находим соответствующий публичный ключ.
3. Декодируем JWT с проверкой подписи (RS256), audience (наш Bundle ID), issuer.
4. Возвращаем payload: `sub` (стабильный Apple user ID), `email`, `email_verified`.

DEV_MODE: если identity_token=="DEV_STUB" — возвращаем фейковый payload без реальной
проверки. Это нужно для тестирования iOS-клиента в симуляторе/без entitlement,
когда нельзя получить реальный SiwA-токен.

Не требует Apple Developer Program — это публичный endpoint (документация:
https://developer.apple.com/documentation/sign_in_with_apple).
"""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx
from fastapi import HTTPException, status
from jose import JWTError, jwk, jwt

from app.core.config import get_settings

logger = logging.getLogger(__name__)
settings = get_settings()

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"
JWKS_CACHE_TTL_SECONDS = 3600  # 1 час
HTTPX_TIMEOUT_SECONDS = 5.0

# In-memory кеш JWKS: {"keys": {...}, "fetched_at": float}.
# Не используем app.state, чтобы модуль не зависел от FastAPI request.
_jwks_cache: dict[str, Any] = {"keys": None, "fetched_at": 0.0}


async def _fetch_jwks(force: bool = False) -> dict[str, Any]:
    """Возвращает Apple JWKS (всегда dict с ключом 'keys').

    Кешируется на JWKS_CACHE_TTL_SECONDS. При сетевой ошибке (если кеш есть)
    возвращает старый кеш — лучше принять токен, чем сломать вход.
    """
    now = time.time()
    cached = _jwks_cache.get("keys")
    fetched_at = _jwks_cache.get("fetched_at", 0.0)

    if not force and cached and now - fetched_at < JWKS_CACHE_TTL_SECONDS:
        return cached

    try:
        async with httpx.AsyncClient(timeout=HTTPX_TIMEOUT_SECONDS) as client:
            response = await client.get(APPLE_JWKS_URL)
            response.raise_for_status()
            data = response.json()
        _jwks_cache["keys"] = data
        _jwks_cache["fetched_at"] = now
        logger.info("Apple JWKS обновлён (получено %d ключей)", len(data.get("keys", [])))
        return data
    except httpx.HTTPError as exc:
        if cached:
            logger.warning("Не удалось обновить Apple JWKS, используем кеш: %s", exc)
            return cached
        logger.error("Apple JWKS unavailable: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Не удалось проверить токен Apple (JWKS unavailable). Попробуйте позже.",
        ) from exc


def _find_key(jwks: dict[str, Any], kid: str) -> dict[str, Any] | None:
    for key in jwks.get("keys", []):
        if key.get("kid") == kid:
            return key
    return None


async def verify_apple_identity_token(
    id_token: str,
    *,
    dev_stub_device_id: str | None = None,
) -> dict[str, Any]:
    """Проверяет Apple identity_token и возвращает payload.

    Args:
        id_token: signed JWT от Apple (или ``"DEV_STUB"`` в DEV_MODE).
        dev_stub_device_id: при DEV_STUB используется как фиктивный ``apple_sub``,
            чтобы разные тестовые устройства соответствовали разным user'ам.

    Raises:
        HTTPException 401: токен невалиден / просрочен / подделка / неверный audience.
        HTTPException 503: Apple JWKS недоступен и нет кеша.

    Returns:
        Payload с минимум: ``sub`` (Apple user ID, стабильный), ``email``,
        ``email_verified``. ``email`` может отсутствовать на повторных входах
        (Apple отдаёт его только при первой авторизации, если scope=email).
    """
    # ── DEV_MODE-stub ──────────────────────────────────────────────
    # Позволяет тестировать /auth/apple flow без реального SiwA-токена.
    # Стаб включается только если DEV_MODE=true (т.е. на продакшене недоступен).
    if settings.DEV_MODE and id_token == "DEV_STUB":
        # apple_sub привязываем к device_id, чтобы разные устройства давали
        # разных тестовых user'ов. Email тоже делаем уникальным.
        suffix = (dev_stub_device_id or "default")[-8:] or "default"
        logger.warning(
            "DEV_MODE: пропускаем проверку Apple identity_token (DEV_STUB suffix=%s)",
            suffix,
        )
        return {
            "sub": f"dev-apple-stub-{suffix}",
            "email": f"dev-apple-{suffix}@monpapa.local",
            "email_verified": True,
        }

    if not id_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="identity_token отсутствует",
        )

    # Извлекаем kid из header'a JWT, чтобы выбрать правильный публичный ключ.
    try:
        unverified_header = jwt.get_unverified_header(id_token)
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Невалидный заголовок токена Apple: {exc}",
        ) from exc

    kid = unverified_header.get("kid")
    if not kid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="В заголовке токена Apple отсутствует kid",
        )

    # Пытаемся найти ключ. Если не нашли — обновляем JWKS принудительно
    # (Apple ротирует ключи; новый kid появляется до того, как старый протухает).
    jwks = await _fetch_jwks()
    key = _find_key(jwks, kid)
    if key is None:
        jwks = await _fetch_jwks(force=True)
        key = _find_key(jwks, kid)
    if key is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Публичный ключ Apple для kid={kid} не найден",
        )

    # Construct PEM-key для python-jose.
    public_key = jwk.construct(key, algorithm=key.get("alg", "RS256"))

    try:
        payload = jwt.decode(
            id_token,
            public_key.to_pem().decode("utf-8") if hasattr(public_key, "to_pem") else key,
            algorithms=["RS256"],
            audience=settings.APPLE_BUNDLE_ID,
            issuer=APPLE_ISSUER,
        )
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Apple identity_token невалиден: {exc}",
        ) from exc

    if not payload.get("sub"):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Apple payload не содержит sub",
        )

    return payload
