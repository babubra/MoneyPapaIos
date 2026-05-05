"""AI API — Парсинг текста и аудио через AiTunnel (OpenAI-совместимый прокси → Gemini).

POST /api/v1/ai/parse       — текстовый запрос
POST /api/v1/ai/parse-audio — аудиозапись (multipart)
POST /api/v1/ai/mapping     — UPSERT auto-learn маппинга

Категории и контрагенты передаются клиентом в теле запроса (offline-first).

Auth Model C:
  • Все эндпоинты требуют авторизованного user (require_user).
  • Trial-gate: если subscription_status != "active" и ai_trial_used >= AI_TRIAL_LIMIT
    → 402 Payment Required. После каждого успешного вызова (для не-Premium) счётчик
    инкрементится. Premium-юзеры безлимитны в текущей итерации.
  • Старый per-device rate-limit (50/day text, 5/hour audio) удалён вместе с
    /auth/device. Защита от спама внутри одного user'а — отдельная задача
    (например, daily cap для Premium).
"""

import base64
import json
import logging
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from openai import AsyncOpenAI, APIStatusError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_user
from app.core.config import get_settings
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt
from app.db.models import CategoryMapping, User
from app.db.session import get_db
from app.schemas import MappingUpsertRequest, ParseTextRequest

logger = logging.getLogger(__name__)
settings = get_settings()
router = APIRouter()


# ── Singleton AI-клиент из app.state ──────────────────────────────
# Клиент создаётся ОДИН РАЗ при старте приложения (lifespan в main.py)
# и переиспользуется всеми запросами — httpx держит пул соединений.

def get_ai_client(request: Request) -> AsyncOpenAI:
    """Dependency: возвращает singleton AsyncOpenAI-клиент из app.state."""
    return request.app.state.ai_client


# ── Trial gate ────────────────────────────────────────────────────

def _is_premium(user: User) -> bool:
    """Активна ли подписка прямо сейчас.

    Premium = subscription_status="active" И (expires_at IS NULL ИЛИ expires_at > now).
    NULL у expires_at трактуем как "бессрочно" — это сценарий внутреннего тестирования.
    """
    if user.subscription_status != "active":
        return False
    if user.subscription_expires_at is None:
        return True
    now = datetime.now(timezone.utc)
    expires = user.subscription_expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return expires > now


async def _check_trial(user: User, db: AsyncSession) -> None:
    """Гейт ПЕРЕД вызовом AI: 402 если trial исчерпан, иначе пропускаем дальше.

    НЕ инкрементирует счётчик — это делается отдельно через _consume_trial()
    ПОСЛЕ успешного AI-вызова. Раньше эти две вещи были в одном методе, что
    приводило к несправедливому списанию trial при сбоях AI-сервиса (502/503,
    невалидный JSON после ретраев, AITUNNEL_API_KEY не настроен — юзер не
    виноват, но trial уже потерян).

    Premium-юзеры пропускают check полностью.
    """
    if _is_premium(user):
        return

    if user.ai_trial_used >= settings.AI_TRIAL_LIMIT:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=(
                f"AI trial исчерпан ({user.ai_trial_used}/{settings.AI_TRIAL_LIMIT}). "
                "Оформите подписку, чтобы продолжить."
            ),
            headers={"X-AI-Trial-Used": str(user.ai_trial_used),
                     "X-AI-Trial-Limit": str(settings.AI_TRIAL_LIMIT)},
        )


async def _consume_trial(user: User, db: AsyncSession) -> None:
    """Инкрементирует ai_trial_used ПОСЛЕ успешного AI-вызова.

    Что считается "успешным": _call_ai_text/_call_ai_audio вернул валидный
    JSON-ответ от Gemini — даже если status="off_topic" / "вопрос не в тему".
    Это справедливо: модель отработала, токены реально потрачены, и мы за
    них заплатили. Иначе юзер может фармить бесплатные вызовы вопросами
    "какая погода?", сливая наш AI-бюджет.

    Что НЕ считается успехом (этот метод НЕ вызывается):
      • HTTPException 502/503 — внешний AI-сервис упал
      • HTTPException 422 — слишком длинный текст / битый multipart
      • Любой exception до возврата result юзеру

    Premium-юзеры пропускают (их trial-счётчик не имеет смысла).
    """
    if _is_premium(user):
        return
    user.ai_trial_used += 1
    await db.flush()


# ── Загрузка маппингов ────────────────────────────────────────────

async def _load_user_mappings(user_id: int, db: AsyncSession) -> list[dict]:
    """Загружает маппинги пользователя для промпта."""
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


def _today_str() -> str:
    return date.today().isoformat()  # "YYYY-MM-DD"


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
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
):
    """Парсит текстовое описание транзакции через Gemini (via aitunnel.ru).

    Trial-gate: free-юзеры расходуют 1 запрос за каждый вызов; при исчерпании — 402.
    """
    logger.info(f"\n{'='*60}")
    logger.info(f"📝 PARSE TEXT | user_id={user.id} sub={user.subscription_status} "
                f"trial={user.ai_trial_used}/{settings.AI_TRIAL_LIMIT} locale={body.locale}")
    logger.info(f"   Текст: \"{body.text}\"")
    logger.info(f"   Категории ({len(body.categories)}): {[c.name for c in body.categories]}")
    logger.info(f"   Контрагенты ({len(body.counterparts)}): {[cp.name for cp in body.counterparts]}")

    if len(body.text) > settings.AI_MAX_TEXT_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Текст слишком длинный. Максимум {settings.AI_MAX_TEXT_LENGTH} символов.",
        )

    # Trial-gate: 402 если free и trial исчерпан. Инкремент НЕ здесь — после AI.
    await _check_trial(user, db)

    mappings = await _load_user_mappings(user.id, db)
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

    # Если AI упадёт (502/503/timeout), exception пробросится наверх и
    # _consume_trial НЕ выполнится — trial остаётся целым.
    result = await _call_ai_text(ai_client, user_prompt)

    # Списываем trial только если AI реально отработал и вернул валидный JSON.
    # Off-topic ответ ("вопрос не в тему") тоже считается успехом — мы за токены
    # уже заплатили.
    await _consume_trial(user, db)

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
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
):
    """Парсит голосовое описание транзакции через Gemini (via aitunnel.ru).

    Trial-gate: free-юзеры расходуют 1 запрос за каждый вызов; при исчерпании — 402.
    Принимает аудиофайл + категории/контрагенты как multipart/form-data.
    """
    logger.info(f"\n{'='*60}")
    logger.info(f"🎤 PARSE AUDIO | user_id={user.id} sub={user.subscription_status} "
                f"trial={user.ai_trial_used}/{settings.AI_TRIAL_LIMIT} locale={locale}")
    logger.info(f"   Файл: {audio.filename}, size={audio.size}, type={audio.content_type}")

    # Trial-gate: 402 если free и trial исчерпан. Инкремент НЕ здесь — после AI.
    await _check_trial(user, db)

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

    mappings = await _load_user_mappings(user.id, db)
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

    # Если AI упадёт (502/503/timeout), exception пробросится наверх и
    # _consume_trial НЕ выполнится — trial остаётся целым.
    result = await _call_ai_audio(ai_client, audio_data, mime_type, user_prompt)

    # Списываем trial только если AI реально отработал (включая off-topic responses).
    await _consume_trial(user, db)

    logger.info(f"   ✅ Результат: status={result.get('status')} type={result.get('type')} "
                f"amount={result.get('amount')} cat=\"{result.get('category_name')}\" "
                f"item_phrase=\"{result.get('item_phrase')}\"")
    logger.info(f"{'='*60}\n")
    return result


# ── UPSERT Mapping ─────────────────────────────────────────────────

@router.post("/mapping", summary="Сохранить маппинг товар → категория")
async def upsert_mapping(
    body: MappingUpsertRequest,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
):
    """Создаёт или обновляет маппинг item_phrase → category.

    - Если маппинг не существует → INSERT (weight=1)
    - Если та же категория → weight += 1
    - Если другая категория (override) → UPDATE category, weight = 1
    """
    user_id = user.id
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
