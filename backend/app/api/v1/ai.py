"""AI API — Парсинг текста и аудио через AiTunnel (OpenAI-совместимый прокси → Gemini).

POST /api/v1/ai/parse       — текстовый запрос
POST /api/v1/ai/parse-audio — аудиозапись (multipart)

Категории и контрагенты передаются клиентом в теле запроса (offline-first).
Rate limiting: 50 текстовых/day, 5 аудио/hour на deviceId.
"""

import base64
import json
import logging
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from openai import AsyncOpenAI, APIStatusError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt
from app.db.models import Device
from app.db.session import get_db
from app.schemas import ParseTextRequest

logger = logging.getLogger(__name__)
settings = get_settings()
router = APIRouter()

bearer_scheme = HTTPBearer(auto_error=False)


# ── Singleton AI-клиент из app.state ──────────────────────────────
# Клиент создаётся ОДИН РАЗ при старте приложения (lifespan в main.py)
# и переиспользуется всеми запросами — httpx держит пул соединений.

def get_ai_client(request: Request) -> AsyncOpenAI:
    """Dependency: возвращает singleton AsyncOpenAI-клиент из app.state."""
    return request.app.state.ai_client


# ── Dependency: текущее устройство из Bearer-токена ───────────────

async def require_device(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> Device:
    """Валидирует Bearer-токен и возвращает Device.

    401 — токен отсутствует или невалиден.
    403 — устройство заблокировано.
    """
    from app.core.security import decode_access_token

    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация",
            headers={"WWW-Authenticate": "Bearer"},
        )

    device_id = decode_access_token(credentials.credentials)
    if not device_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Невалидный или истёкший токен",
            headers={"WWW-Authenticate": "Bearer"},
        )

    result = await db.execute(select(Device).where(Device.device_id == device_id))
    device = result.scalar_one_or_none()

    if device is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Устройство не найдено",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if device.is_blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Устройство заблокировано",
        )

    return device


# ── Rate limiting ──────────────────────────────────────────────────

def _today_str() -> str:
    return date.today().isoformat()  # "YYYY-MM-DD"


def _current_hour_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H")  # "YYYY-MM-DDTHH"


async def _check_and_increment_text_limit(device: Device, db: AsyncSession) -> None:
    """Проверяет дневной лимит текстовых запросов. Сбрасывает при новом дне."""
    today = _today_str()

    if device.ai_requests_date != today:
        device.ai_requests_today = 0
        device.ai_requests_date = today

    if device.ai_requests_today >= settings.AI_RATE_LIMIT_DAILY:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Превышен дневной лимит AI-запросов ({settings.AI_RATE_LIMIT_DAILY}/день). Попробуйте завтра.",
            headers={"Retry-After": "86400"},
        )

    device.ai_requests_today += 1
    await db.flush()


async def _check_and_increment_audio_limit(device: Device, db: AsyncSession) -> None:
    """Проверяет часовой лимит аудио-запросов. Сбрасывает при новом часе."""
    current_hour = _current_hour_str()

    if device.ai_audio_hour != current_hour:
        device.ai_audio_requests_hour = 0
        device.ai_audio_hour = current_hour

    if device.ai_audio_requests_hour >= settings.AI_RATE_LIMIT_AUDIO_HOURLY:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Превышен лимит аудио-запросов ({settings.AI_RATE_LIMIT_AUDIO_HOURLY}/час). Попробуйте позже.",
            headers={"Retry-After": "3600"},
        )

    device.ai_audio_requests_hour += 1
    await db.flush()


# ── Вызов AI (OpenAI-compatible) ──────────────────────────────────

async def _call_ai_text(client: AsyncOpenAI, user_prompt: str) -> dict:
    """Вызывает aitunnel.ru с текстовым промтом, возвращает распарсенный JSON."""
    if not settings.AITUNNEL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AITUNNEL_API_KEY не настроен на сервере",
        )

    try:
        response = await client.chat.completions.create(
            model=settings.AI_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.1,
            response_format={"type": "json_object"},
        )
        text = response.choices[0].message.content.strip()
        return json.loads(text)

    except APIStatusError as e:
        logger.error(f"AiTunnel API ошибка {e.status_code}: {e.message}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Ошибка AI-сервиса: {e.message}",
        )
    except json.JSONDecodeError as e:
        logger.error(f"AI вернул невалидный JSON: {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="AI вернул невалидный ответ",
        )
    except Exception as e:
        logger.error(f"Неожиданная ошибка вызова AI: {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Ошибка AI-сервиса: {str(e)}",
        )


async def _call_ai_audio(client: AsyncOpenAI, audio_data: bytes, mime_type: str, user_prompt: str) -> dict:
    """Вызывает aitunnel.ru с аудио (base64) + текстовым промтом.

    Использует мультимодальный формат OpenAI (image_url-подобный для аудио).
    """
    if not settings.AITUNNEL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AITUNNEL_API_KEY не настроен на сервере",
        )

    try:
        audio_b64 = base64.b64encode(audio_data).decode("utf-8")

        response = await client.chat.completions.create(
            model=settings.AI_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "input_audio",
                            "input_audio": {
                                "data": audio_b64,
                                "format": mime_type.split("/")[-1],  # "m4a", "wav", etc.
                            },
                        },
                        {"type": "text", "text": user_prompt},
                    ],
                },
            ],
            temperature=0.1,
            response_format={"type": "json_object"},
        )
        text = response.choices[0].message.content.strip()
        return json.loads(text)

    except APIStatusError as e:
        logger.error(f"AiTunnel API ошибка {e.status_code}: {e.message}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Ошибка AI-сервиса: {e.message}",
        )
    except json.JSONDecodeError as e:
        logger.error(f"AI вернул невалидный JSON: {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="AI вернул невалидный ответ",
        )
    except Exception as e:
        logger.error(f"Неожиданная ошибка вызова AI (аудио): {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Ошибка AI-сервиса: {str(e)}",
        )


# ── Endpoints ──────────────────────────────────────────────────────

@router.post("/parse", summary="Парсинг текстовой транзакции")
async def parse_text(
    body: ParseTextRequest,
    device: Device = Depends(require_device),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
):
    """Парсит текстовое описание транзакции через Gemini (via aitunnel.ru).

    Принимает текст + список категорий/контрагентов от клиента.
    Возвращает структурированный JSON для preview-экрана iOS.
    Лимит: 50 запросов/день на устройство.
    """
    if len(body.text) > settings.AI_MAX_TEXT_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Текст слишком длинный. Максимум {settings.AI_MAX_TEXT_LENGTH} символов.",
        )

    await _check_and_increment_text_limit(device, db)

    user_prompt = build_ai_prompt(
        user_text=body.text,
        categories=[c.model_dump() for c in body.categories],
        counterparts=[cp.model_dump() for cp in body.counterparts],
        today=_today_str(),
    )

    return await _call_ai_text(ai_client, user_prompt)


@router.post("/parse-audio", summary="Парсинг голосовой транзакции")
async def parse_audio(
    audio: UploadFile = File(..., description="Аудиофайл (m4a, wav, webm)"),
    categories: str = Form(default="[]", description="JSON-массив категорий"),
    counterparts: str = Form(default="[]", description="JSON-массив контрагентов"),
    device: Device = Depends(require_device),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
):
    """Парсит голосовое описание транзакции через Gemini (via aitunnel.ru).

    Принимает аудиофайл + категории/контрагенты как multipart/form-data.
    Лимит: 5 аудио-запросов/час на устройство.
    """
    await _check_and_increment_audio_limit(device, db)

    audio_data = await audio.read()
    mime_type = audio.content_type or "audio/m4a"

    try:
        categories_list = json.loads(categories)
        counterparts_list = json.loads(counterparts)
    except json.JSONDecodeError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Невалидный JSON в categories или counterparts",
        )

    user_prompt = build_ai_prompt(
        user_text="[аудиозапись — расшифруй и распарси]",
        categories=categories_list,
        counterparts=counterparts_list,
        today=_today_str(),
    )

    return await _call_ai_audio(ai_client, audio_data, mime_type, user_prompt)
