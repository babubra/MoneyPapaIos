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
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt
from app.db.models import CategoryMapping, Device
from app.db.session import get_db
from app.schemas import MappingUpsertRequest, ParseTextRequest

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


# ── Загрузка маппингов ────────────────────────────────────────────

async def _load_user_mappings(user_id: int | None, db: AsyncSession) -> list[dict]:
    """Загружает маппинги пользователя для промпта. Пустой список если не залогинен."""
    if user_id is None:
        return []
    result = await db.execute(
        select(CategoryMapping)
        .where(CategoryMapping.user_id == user_id)
        .order_by(CategoryMapping.weight.desc())
    )
    mappings = result.scalars().all()
    return [
        {"item_phrase": m.item_phrase, "category_name": m.category_name, "weight": m.weight}
        for m in mappings
    ]


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

# Поля, в которых AI иногда возвращает строку "null"/"None"/"" вместо JSON null.
# Нормализуем их в реальный None, чтобы клиент не получил литерал "null".
_NULLABLE_FIELDS = {
    "type", "amount", "currency", "date", "raw_text", "item_phrase",
    "category_id", "category_name", "category_icon",
    "category_parent_id", "category_parent_name", "category_parent_icon",
    "counterpart_id", "counterpart_name",
    "due_date", "payment_flow", "message",
}


def _normalize_null_strings(data: dict) -> dict:
    """AI (Gemini) иногда квотит null: 'null', 'None', ''. Приводим к настоящему None."""
    if not isinstance(data, dict):
        return data
    for key in _NULLABLE_FIELDS:
        val = data.get(key)
        if isinstance(val, str) and val.strip().lower() in {"null", "none", ""}:
            data[key] = None
    return data


def _sanitize_json(text: str) -> str:
    """Очищает ответ AI от типичных проблем с JSON.

    - Убирает markdown-обёртки (```json ... ```)
    - Убирает trailing commas перед } и ]
    - Убирает комментарии // ...
    """
    import re

    # Убираем markdown-обёртки
    text = text.strip()
    if text.startswith("```"):
        # Убираем первую строку (```json) и последнюю (```)
        lines = text.split("\n")
        if lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines)

    # Убираем однострочные комментарии (// ...)
    text = re.sub(r'//[^\n]*', '', text)

    # Убираем trailing commas: ,} → } и ,] → ]
    text = re.sub(r',\s*}', '}', text)
    text = re.sub(r',\s*]', ']', text)

    return text.strip()


async def _call_ai_text(client: AsyncOpenAI, user_prompt: str) -> dict:
    """Вызывает aitunnel.ru с текстовым промтом, возвращает распарсенный JSON.
    При невалидном ответе — автоматический retry (до 2 попыток)."""
    if not settings.AITUNNEL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AITUNNEL_API_KEY не настроен на сервере",
        )

    max_retries = 2
    last_error = None

    logger.info(f"\n{'='*20} FULL AI PROMPT {'='*20}\n[SYSTEM PROMPT]:\n{SYSTEM_PROMPT}\n\n[USER PROMPT]:\n{user_prompt}\n{'='*56}")
    for attempt in range(max_retries):
        try:
            response = await client.chat.completions.create(
                model=settings.AI_MODEL,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                temperature=0.1,
                max_tokens=1024,
                response_format={"type": "json_object"},
            )
            text = response.choices[0].message.content.strip()
            logger.info(f"   🤖 AI raw (попытка {attempt+1}): {text[:500]}")

            # Парсинг JSON
            try:
                return _normalize_null_strings(json.loads(text))
            except json.JSONDecodeError:
                sanitized = _sanitize_json(text)
                logger.warning(f"AI невалидный JSON, очистка: {text[:200]}...")
                try:
                    return _normalize_null_strings(json.loads(sanitized))
                except json.JSONDecodeError as e:
                    last_error = e
                    logger.warning(f"   ⚠️ Попытка {attempt+1}/{max_retries} не удалась: {e}")
                    continue  # retry

        except APIStatusError as e:
            logger.error(f"AiTunnel API ошибка {e.status_code}: {e.message}")
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"Ошибка AI-сервиса: {e.message}",
            )
        except Exception as e:
            last_error = e
            logger.warning(f"   ⚠️ Попытка {attempt+1}/{max_retries} ошибка: {e}")
            continue

    # Все попытки исчерпаны
    logger.error(f"AI JSON невалиден после {max_retries} попыток: {last_error}")
    raise HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail="AI вернул невалидный ответ. Попробуйте ещё раз.",
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
        try:
            return _normalize_null_strings(json.loads(text))
        except json.JSONDecodeError:
            return _normalize_null_strings(json.loads(_sanitize_json(text)))

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
    """Парсит текстовое описание транзакции через Gemini (via aitunnel.ru)."""
    logger.info(f"\n{'='*60}")
    logger.info(f"📝 PARSE TEXT | device={device.device_id[:8]}... locale={body.locale}")
    logger.info(f"   Текст: \"{body.text}\"")
    logger.info(f"   Категории ({len(body.categories)}): {[c.name for c in body.categories]}")
    logger.info(f"   Контрагенты ({len(body.counterparts)}): {[cp.name for cp in body.counterparts]}")

    if len(body.text) > settings.AI_MAX_TEXT_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Текст слишком длинный. Максимум {settings.AI_MAX_TEXT_LENGTH} символов.",
        )

    await _check_and_increment_text_limit(device, db)

    # Загружаем маппинги (только для залогиненных)
    mappings = await _load_user_mappings(device.user_id, db)
    if mappings:
        logger.info(f"   🧠 Маппинги ({len(mappings)}): {[(m['item_phrase'], m['category_name'], m['weight']) for m in mappings[:5]]}...")

    user_prompt = build_ai_prompt(
        user_text=body.text,
        categories=[c.model_dump() for c in body.categories],
        counterparts=[cp.model_dump() for cp in body.counterparts],
        today=_today_str(),
        locale=body.locale,
        mappings=mappings or None,
    )

    result = await _call_ai_text(ai_client, user_prompt)
    logger.info(f"   ✅ Результат: status={result.get('status')} type={result.get('type')} "
                f"amount={result.get('amount')} cat=\"{result.get('category_name')}\" "
                f"item_phrase=\"{result.get('item_phrase')}\" new={result.get('category_is_new')}")
    logger.info(f"{'='*60}\n")
    return result


@router.post("/parse-audio", summary="Парсинг голосовой транзакции")
async def parse_audio(
    audio: UploadFile = File(..., description="Аудиофайл (m4a, wav, webm)"),
    categories: str = Form(default="[]", description="JSON-массив категорий"),
    counterparts: str = Form(default="[]", description="JSON-массив контрагентов"),
    locale: str = Form(default="ru", description="Языковая локаль клиента"),
    device: Device = Depends(require_device),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
):
    """Парсит голосовое описание транзакции через Gemini (via aitunnel.ru).

    Принимает аудиофайл + категории/контрагенты как multipart/form-data.
    Лимит: 5 аудио-запросов/час на устройство.
    """
    logger.info(f"\n{'='*60}")
    logger.info(f"🎤 PARSE AUDIO | device={device.device_id[:8]}... locale={locale}")
    logger.info(f"   Файл: {audio.filename}, size={audio.size}, type={audio.content_type}")

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

    logger.info(f"   Категории ({len(categories_list)}): {[c.get('name') for c in categories_list]}")

    # Загружаем маппинги (только для залогиненных)
    mappings = await _load_user_mappings(device.user_id, db)
    if mappings:
        logger.info(f"   🧠 Маппинги ({len(mappings)}): {[(m['item_phrase'], m['category_name']) for m in mappings[:5]]}...")

    user_prompt = build_ai_prompt(
        user_text="[аудиозапись — расшифруй и распарси]",
        categories=categories_list,
        counterparts=counterparts_list,
        today=_today_str(),
        locale=locale,
        mappings=mappings or None,
    )

    result = await _call_ai_audio(ai_client, audio_data, mime_type, user_prompt)
    logger.info(f"   ✅ Результат: status={result.get('status')} type={result.get('type')} "
                f"amount={result.get('amount')} cat=\"{result.get('category_name')}\" "
                f"item_phrase=\"{result.get('item_phrase')}\"")
    logger.info(f"{'='*60}\n")
    return result


# ── UPSERT Mapping ─────────────────────────────────────────────────

@router.post("/mapping", summary="Сохранить маппинг товар → категория")
async def upsert_mapping(
    body: MappingUpsertRequest,
    device: Device = Depends(require_device),
    db: AsyncSession = Depends(get_db),
):
    """Создаёт или обновляет маппинг item_phrase → category.

    - Если пользователь не залогинен → skip
    - Если маппинг не существует → INSERT (weight=1)
    - Если та же категория → weight += 1
    - Если другая категория (override) → UPDATE category, weight = 1
    """
    if device.user_id is None:
        return {"status": "skipped", "reason": "user not authenticated"}

    user_id = device.user_id
    phrase_lower = body.item_phrase.strip().lower()

    # Ищем существующий маппинг
    existing_result = await db.execute(
        select(CategoryMapping).where(
            CategoryMapping.user_id == user_id,
            func.lower(CategoryMapping.item_phrase) == phrase_lower,
        )
    )
    existing = existing_result.scalar_one_or_none()

    if existing is None:
        # Новый маппинг — сохраняем client_id категории напрямую (offline-first)
        mapping = CategoryMapping(
            user_id=user_id,
            item_phrase=body.item_phrase.strip(),
            category_id=body.category_id,
            category_name=body.category_name,
            weight=1,
        )
        db.add(mapping)
        logger.info(f"🧠 Mapping INSERT: '{body.item_phrase}' → '{body.category_name}' (user={user_id})")
    elif existing.category_id == body.category_id:
        # Confirm — та же категория
        existing.weight += 1
        existing.updated_at = datetime.now(timezone.utc)
        logger.info(f"🧠 Mapping CONFIRM: '{body.item_phrase}' → '{body.category_name}' (w={existing.weight}, user={user_id})")
    else:
        # Override — смена категории, сброс веса
        existing.category_id = body.category_id
        existing.category_name = body.category_name
        existing.weight = 1
        existing.updated_at = datetime.now(timezone.utc)
        logger.info(f"🧠 Mapping OVERRIDE: '{body.item_phrase}' → '{body.category_name}' (reset w=1, user={user_id})")

    await db.commit()
    return {"status": "ok"}
