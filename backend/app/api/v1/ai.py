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
from app.core.idempotency import IdempotencyState, IdempotencyStore
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt
from app.db.models import CategoryMapping, User
from app.db.session import get_db
from app.schemas import MappingUpsertRequest, ParseTextRequest

logger = logging.getLogger(__name__)
settings = get_settings()
router = APIRouter()


# Whitelist допустимых MIME-типов для /parse-audio. Всё остальное → 415.
_ALLOWED_AUDIO_MIME: frozenset[str] = frozenset({
    "audio/m4a", "audio/x-m4a", "audio/mp4",
    "audio/wav", "audio/wave", "audio/x-wav",
    "audio/webm",
    "audio/mpeg", "audio/mp3",
})

# Максимальный размер аудио-файла в байтах. Защита от OOM (UploadFile.read()
# тянет всё в память) и от траты AI-токенов на гигантские записи.
_MAX_AUDIO_BYTES: int = settings.AI_MAX_AUDIO_SIZE_MB * 1024 * 1024


# ── Singleton AI-клиент из app.state ──────────────────────────────
# Клиент создаётся ОДИН РАЗ при старте приложения (lifespan в main.py)
# и переиспользуется всеми запросами — httpx держит пул соединений.

def get_ai_client(request: Request) -> AsyncOpenAI:
    """Dependency: возвращает singleton AsyncOpenAI-клиент из app.state."""
    return request.app.state.ai_client


def get_idempotency_store(request: Request) -> IdempotencyStore:
    """Dependency: возвращает singleton in-memory стор идемпотентности из app.state."""
    return request.app.state.idempotency_store


# Максимальная длина Idempotency-Key. UUID в hex = 36 символов; даём с запасом для
# нестандартных форматов (UUID без дефисов, ULID, etc.), но отсекаем мусорные ключи
# на 1KB чтобы не раздувать память стора и не открывать DoS-вектор «зловредный
# клиент шлёт миллион уникальных ключей».
_IDEMPOTENCY_KEY_MAX_LEN = 128


def _resolve_idempotency_key(request: Request, user_id: int) -> str | None:
    """Извлекает Idempotency-Key из header'а и формирует составной ключ.

    Возвращает:
      • `None` если header отсутствует или невалиден (старые клиенты без поддержки
        идемпотентности работают как раньше — нет cache, нет 409).
      • `f"{user_id}:{key}"` для изоляции между юзерами (один юзер не может
        прочитать кэшированный ответ другого через коллизию ключа).

    Невалидным считается пустой ключ или ключ длиннее `_IDEMPOTENCY_KEY_MAX_LEN`.
    На невалид НЕ кидаем 422 — back-compat-policy: header опциональный, мусорный
    игнорируется как отсутствующий.
    """
    raw = request.headers.get("Idempotency-Key")
    if not raw:
        return None
    key = raw.strip()
    if not key or len(key) > _IDEMPOTENCY_KEY_MAX_LEN:
        logger.warning("Invalid Idempotency-Key (len=%s) — ignored", len(raw))
        return None
    return f"{user_id}:{key}"


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


def _utc_today_str() -> str:
    """YYYY-MM-DD в UTC. Используется для Premium daily-cap reset-logic.

    Отличается от _today_str() (local date) тем, что детерминирован — не зависит
    от TZ сервера. Premium-юзер не должен получать «бесплатные» дополнительные
    запросы при перезагрузке сервера в другую TZ.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _reset_premium_counters_if_needed(user: User) -> None:
    """Обнуляет Premium daily-cap счётчики при наступлении новых UTC-суток.

    Идемпотентно: повторный вызов в тот же день — no-op. Mutates `user` in-place,
    но НЕ flushe'ит — flush делает вызывающий после своих собственных мутаций.
    """
    today = _utc_today_str()
    if user.ai_requests_reset_date != today:
        user.ai_requests_today = 0
        user.ai_audio_requests_today = 0
        user.ai_requests_reset_date = today


async def _check_trial(user: User, db: AsyncSession, *, is_audio: bool = False) -> None:
    """Гейт ПЕРЕД вызовом AI: 402 (free trial исчерпан) либо 429 (Premium daily-cap).

    НЕ инкрементирует счётчики — это делается через _consume_trial() ПОСЛЕ
    успешного AI-вызова. Раньше check и consume были в одном методе, что
    приводило к несправедливому списанию при сбоях AI-сервиса (502/503,
    невалидный JSON, AITUNNEL_API_KEY не настроен — юзер не виноват).

    Free-юзеры: 402 если ai_trial_used >= AI_TRIAL_LIMIT (lifetime).
    Premium-юзеры: 429 если соответствующий daily-counter >= cap. Сброс
    в полночь UTC. Это safety-net против угнанного JWT и retry-loop'ов
    на клиенте — легитимный Premium-юзер с типичным use не упирается.
    """
    if _is_premium(user):
        _reset_premium_counters_if_needed(user)
        if is_audio:
            used = user.ai_audio_requests_today
            limit = settings.AI_PREMIUM_DAILY_CAP_AUDIO
            kind = "audio"
        else:
            used = user.ai_requests_today
            limit = settings.AI_PREMIUM_DAILY_CAP_TEXT
            kind = "text"
        if used >= limit:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=(
                    f"Дневной лимит Premium ({kind}) достигнут: {used}/{limit}. "
                    "Сброс в полночь UTC."
                ),
                headers={"X-AI-Daily-Used": str(used),
                         "X-AI-Daily-Limit": str(limit),
                         "X-AI-Daily-Kind": kind},
            )
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


async def _consume_trial(user: User, db: AsyncSession, *, is_audio: bool = False) -> None:
    """Инкрементирует соответствующий счётчик ПОСЛЕ успешного AI-вызова.

    Что считается "успешным": _call_ai_text/_call_ai_audio вернул валидный
    JSON-ответ от Gemini — даже если status="off_topic" / "вопрос не в тему".
    Это справедливо: модель отработала, токены реально потрачены, и мы за
    них заплатили. Иначе юзер может фармить бесплатные вызовы вопросами
    "какая погода?", сливая наш AI-бюджет.

    Что НЕ считается успехом (этот метод НЕ вызывается):
      • HTTPException 502/503 — внешний AI-сервис упал
      • HTTPException 422 — слишком длинный текст / битый multipart
      • Любой exception до возврата result юзеру

    Free: ai_trial_used (lifetime).
    Premium: ai_requests_today либо ai_audio_requests_today (UTC daily).
    """
    if _is_premium(user):
        _reset_premium_counters_if_needed(user)
        if is_audio:
            user.ai_audio_requests_today += 1
        else:
            user.ai_requests_today += 1
        await db.flush()
        return
    user.ai_trial_used += 1
    await db.flush()


# ── Загрузка маппингов ────────────────────────────────────────────

async def _load_user_mappings(user_id: int, db: AsyncSession) -> list[dict]:
    """Загружает топ-N маппингов пользователя для промпта.

    Сортировка по weight DESC — самые подтверждённые маппинги первыми; среди
    равных weights — по updated_at DESC, чтобы выдача была детерминированной
    (иначе при ties Gemini implicit-cache никогда не сработает).

    LIMIT защищает от линейного роста стоимости prompt-а с возрастом аккаунта
    (см. C1.5 в todo/audit/C1_C2_ai_layer.md).
    """
    result = await db.execute(
        select(CategoryMapping)
        .where(CategoryMapping.user_id == user_id)
        .order_by(
            CategoryMapping.weight.desc(),
            CategoryMapping.updated_at.desc(),
        )
        .limit(settings.AI_MAPPINGS_PROMPT_LIMIT)
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


def _log_ai_usage(response, *, mode: str, user_id: int, attempt: int = 1) -> None:
    """Логирует usage tokens из AI response для мониторинга стоимости.

    Baseline до prompt-cache / promptlen-сокращений (см. C1+C2-fixups). Это
    metadata (без PII) — безопасно на INFO в проде. Лог пишется на каждом
    billable вызове (включая ретраи в _call_ai_text), потому что каждая
    попытка создаёт реальную трату токенов у провайдера.

    Поля:
      • prompt / completion / total — есть всегда у OpenAI-совместимых API
      • cached — prompt_tokens_details.cached_tokens; у aitunnel может
        отсутствовать, тогда выводим 0 — это сам по себе baseline-сигнал
        «prompt-caching не работает» (см. C1.1).
      • attempt — номер попытки в retry-цикле (1 для первой; для audio всегда 1).
    """
    usage = getattr(response, "usage", None)
    if usage is None:
        logger.warning(
            "AI usage | mode=%s user_id=%s model=%s — usage отсутствует в ответе",
            mode, user_id, settings.AI_MODEL,
        )
        return

    prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0
    completion_tokens = getattr(usage, "completion_tokens", 0) or 0
    total_tokens = getattr(usage, "total_tokens", 0) or 0

    cached_tokens = 0
    details = getattr(usage, "prompt_tokens_details", None)
    if details is not None:
        cached_tokens = getattr(details, "cached_tokens", 0) or 0

    extra = f" attempt={attempt}" if attempt > 1 else ""
    logger.info(
        "AI usage | mode=%s user_id=%s model=%s prompt=%d completion=%d total=%d cached=%d%s",
        mode, user_id, settings.AI_MODEL,
        prompt_tokens, completion_tokens, total_tokens, cached_tokens, extra,
    )


async def _call_ai_text(client: AsyncOpenAI, user_prompt: str, *, user_id: int) -> dict:
    """Вызывает aitunnel.ru с текстовым промтом, возвращает распарсенный JSON.
    При невалидном ответе — автоматический retry (до 2 попыток)."""
    if not settings.AITUNNEL_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AITUNNEL_API_KEY не настроен на сервере",
        )

    max_retries = 2
    last_error = None

    # Полный prompt — это PII (текст транзакции пользователя + список его
    # категорий). Пишем на DEBUG, чтобы в проде на INFO не утекало в stdout.
    logger.debug(
        "FULL AI PROMPT\n[SYSTEM PROMPT]:\n%s\n\n[USER PROMPT]:\n%s",
        SYSTEM_PROMPT, user_prompt,
    )
    for attempt in range(max_retries):
        try:
            response = await client.chat.completions.create(
                model=settings.AI_MODEL,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                # temperature=0 — детерминированный greedy decoding для JSON-парсинга
                # финансовых транзакций. Эмпирически проверено: на gemini-2.5-flash-lite
                # даёт стабильно лучшее качество на ru-кейсах, чем 0.1, и устраняет
                # стохастику в category_name/item_phrase (см. C2.16 в audit/C1_C2_ai_layer.md).
                temperature=0,
                max_tokens=1024,
                response_format={"type": "json_object"},
            )
            _log_ai_usage(response, mode="text", user_id=user_id, attempt=attempt + 1)
            text = response.choices[0].message.content.strip()
            logger.debug("AI raw (попытка %s): %s", attempt + 1, text[:500])

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

async def _call_ai_audio(
    client: AsyncOpenAI,
    audio_data: bytes,
    mime_type: str,
    user_prompt: str,
    *,
    user_id: int,
) -> dict:
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
            # temperature=0 — симметрично _call_ai_text. См. комментарий выше.
            temperature=0,
            max_tokens=1024,
            response_format={"type": "json_object"},
        )
        _log_ai_usage(response, mode="audio", user_id=user_id)
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
    request: Request,
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
    idempotency_store: IdempotencyStore = Depends(get_idempotency_store),
):
    """Парсит текстовое описание транзакции через Gemini (via aitunnel.ru).

    Trial-gate: free-юзеры расходуют 1 запрос за каждый вызов; при исчерпании — 402.
    Поддерживает header `Idempotency-Key`: повторный запрос с тем же ключом в окне
    60s вернёт закэшированный ответ без повторного AI-вызова и без двойного
    списания trial (см. #3 в audit/C1_C2_ai_layer.md).
    """
    # PII-минимизация: на INFO — только метаданные. Сам текст транзакции
    # (PII + финансовая информация) пишется только на DEBUG.
    logger.info(
        "PARSE TEXT | user_id=%s sub=%s trial=%s/%s locale=%s text_len=%s cats=%s cps=%s",
        user.id, user.subscription_status,
        user.ai_trial_used, settings.AI_TRIAL_LIMIT,
        body.locale, len(body.text),
        len(body.categories), len(body.counterparts),
    )
    logger.debug("Текст: %r", body.text)
    logger.debug("Категории: %s", [c.name for c in body.categories])
    logger.debug("Контрагенты: %s", [cp.name for cp in body.counterparts])

    if len(body.text) > settings.AI_MAX_TEXT_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Текст слишком длинный. Максимум {settings.AI_MAX_TEXT_LENGTH} символов.",
        )

    # Idempotency-check: до trial-gate, потому что cached response не должен
    # списать trial повторно. Если ключа в header нет — работаем как раньше,
    # без идемпотентности (back-compat для старых iOS-клиентов).
    composite_key = _resolve_idempotency_key(request, user.id)
    if composite_key is not None:
        state, payload = await idempotency_store.acquire(composite_key)
        if state is IdempotencyState.CACHED:
            logger.info("PARSE TEXT idempotent | user_id=%s state=cached", user.id)
            return payload
        if state is IdempotencyState.IN_FLIGHT:
            logger.info("PARSE TEXT idempotent | user_id=%s state=in_flight → 409", user.id)
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Дубликат запроса: предыдущая попытка ещё выполняется. Подождите.",
            )

    try:
        # Gate: 402 если free trial исчерпан, 429 если Premium daily-cap исчерпан.
        await _check_trial(user, db, is_audio=False)

        mappings = await _load_user_mappings(user.id, db)
        # Счётчик — на INFO (без PII). Сам список phrase→category — DEBUG.
        logger.info(
            "PARSE TEXT mappings | user_id=%s count=%s/%s",
            user.id, len(mappings), settings.AI_MAPPINGS_PROMPT_LIMIT,
        )
        if mappings:
            # item_phrase — слово, которое юзер произнёс/набрал (PII). На DEBUG.
            logger.debug(
                "Mappings (%s): %s",
                len(mappings),
                [(m["item_phrase"], m["category_name"], m["weight"]) for m in mappings[:5]],
            )

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
        result = await _call_ai_text(ai_client, user_prompt, user_id=user.id)

        # Списываем trial только если AI реально отработал и вернул валидный JSON.
        # Off-topic ответ ("вопрос не в тему") тоже считается успехом — мы за токены
        # уже заплатили.
        await _consume_trial(user, db, is_audio=False)

        # Фиксируем результат в idempotency-store, чтобы дубликат-retry получил
        # закэшированный ответ без повторного AI-call и без двойного trial-списания.
        if composite_key is not None:
            await idempotency_store.commit(composite_key, result)

        # Финансовые поля и текст транзакции — на DEBUG, на INFO только статус.
        logger.info(
            "PARSE TEXT done | user_id=%s status=%s new=%s",
            user.id, result.get("status"), result.get("category_is_new"),
        )
        logger.debug(
            "Result: type=%s amount=%s cat=%r item_phrase=%r",
            result.get("type"), result.get("amount"),
            result.get("category_name"), result.get("item_phrase"),
        )
        return result
    except Exception:
        # AI упал / trial исчерпан / любая другая ошибка после acquire — снимаем
        # in-flight-запись, чтобы юзер мог явно ретраить с тем же ключом. Иначе
        # фейл одного вызова блокирует юзера на ttl_seconds.
        if composite_key is not None:
            await idempotency_store.release_failure(composite_key)
        raise


@router.post("/parse-audio", summary="Парсинг голосовой транзакции")
async def parse_audio(
    request: Request,
    audio: UploadFile = File(..., description="Аудиофайл (m4a, wav, webm)"),
    categories: str = Form(default="[]", description="JSON-массив категорий"),
    counterparts: str = Form(default="[]", description="JSON-массив контрагентов"),
    locale: str = Form(default="ru", description="Языковая локаль клиента"),
    user: User = Depends(require_user),
    db: AsyncSession = Depends(get_db),
    ai_client: AsyncOpenAI = Depends(get_ai_client),
    idempotency_store: IdempotencyStore = Depends(get_idempotency_store),
):
    """Парсит голосовое описание транзакции через Gemini (via aitunnel.ru).

    Trial-gate: free-юзеры расходуют 1 запрос за каждый вызов; при исчерпании — 402.
    Принимает аудиофайл + категории/контрагенты как multipart/form-data.
    Idempotency через header `Idempotency-Key` — см. docstring /parse.
    """
    logger.info(
        "PARSE AUDIO | user_id=%s sub=%s trial=%s/%s locale=%s size=%s type=%s",
        user.id, user.subscription_status,
        user.ai_trial_used, settings.AI_TRIAL_LIMIT,
        locale, audio.size, audio.content_type,
    )

    # Content-type whitelist — отсекаем не-аудио сразу, до чтения в память.
    content_type = (audio.content_type or "").lower()
    if content_type not in _ALLOWED_AUDIO_MIME:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=(
                f"Неподдерживаемый формат аудио: {audio.content_type or 'unknown'}. "
                f"Допустимы: m4a, mp3, wav, webm."
            ),
        )

    # Размер: предварительная проверка по UploadFile.size (Content-Length),
    # затем — повторная после чтения, на случай если size не был выставлен.
    if audio.size is not None and audio.size > _MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Аудиофайл слишком большой. Максимум {settings.AI_MAX_AUDIO_SIZE_MB} MB.",
        )

    # Idempotency-check (до trial-gate, чтобы cached response не списал trial повторно).
    composite_key = _resolve_idempotency_key(request, user.id)
    if composite_key is not None:
        state, payload = await idempotency_store.acquire(composite_key)
        if state is IdempotencyState.CACHED:
            logger.info("PARSE AUDIO idempotent | user_id=%s state=cached", user.id)
            return payload
        if state is IdempotencyState.IN_FLIGHT:
            logger.info("PARSE AUDIO idempotent | user_id=%s state=in_flight → 409", user.id)
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Дубликат запроса: предыдущая попытка ещё выполняется. Подождите.",
            )

    try:
        # Gate: 402 если free trial исчерпан, 429 если Premium daily-audio-cap исчерпан.
        await _check_trial(user, db, is_audio=True)

        audio_data = await audio.read()
        if len(audio_data) > _MAX_AUDIO_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"Аудиофайл слишком большой. Максимум {settings.AI_MAX_AUDIO_SIZE_MB} MB.",
            )
        mime_type = content_type or "audio/m4a"

        try:
            categories_list = json.loads(categories)
            counterparts_list = json.loads(counterparts)
        except json.JSONDecodeError:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Невалидный JSON в categories или counterparts",
            )

        # Дублируем cap из ParseTextRequest (Pydantic-схема не применяется к Form-полям).
        # См. C2.7 в todo/audit/C1_C2_ai_layer.md.
        if len(categories_list) > 200 or len(counterparts_list) > 200:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Слишком много категорий или контрагентов (максимум 200).",
            )

        logger.debug("Категории (%s): %s", len(categories_list), [c.get("name") for c in categories_list])

        mappings = await _load_user_mappings(user.id, db)
        # Счётчик — на INFO (без PII). Сам список phrase→category — DEBUG.
        logger.info(
            "PARSE AUDIO mappings | user_id=%s count=%s/%s",
            user.id, len(mappings), settings.AI_MAPPINGS_PROMPT_LIMIT,
        )
        if mappings:
            logger.debug(
                "Mappings (%s): %s",
                len(mappings),
                [(m["item_phrase"], m["category_name"]) for m in mappings[:5]],
            )

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
        result = await _call_ai_audio(ai_client, audio_data, mime_type, user_prompt, user_id=user.id)

        # Списываем trial / Premium daily-audio только если AI реально отработал.
        await _consume_trial(user, db, is_audio=True)

        if composite_key is not None:
            await idempotency_store.commit(composite_key, result)

        logger.info(
            "PARSE AUDIO done | user_id=%s status=%s",
            user.id, result.get("status"),
        )
        logger.debug(
            "Result: type=%s amount=%s cat=%r item_phrase=%r",
            result.get("type"), result.get("amount"),
            result.get("category_name"), result.get("item_phrase"),
        )
        return result
    except Exception:
        if composite_key is not None:
            await idempotency_store.release_failure(composite_key)
        raise


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
        await db.flush()  # чтобы новая запись попала в подсчёт ниже
        logger.info("Mapping INSERT user=%s", user_id)
        logger.debug("  '%s' → '%s'", body.item_phrase, body.category_name)

        # Cap по общему количеству маппингов на юзера. Защита от роста
        # маппинг-таблицы у долгоиграющих пользователей (см. C1.5).
        # Срабатывает только в INSERT-ветке: CONFIRM/OVERRIDE total не растят.
        count_result = await db.execute(
            select(func.count(CategoryMapping.id))
            .where(CategoryMapping.user_id == user_id)
        )
        total = count_result.scalar() or 0
        if total > settings.AI_MAPPINGS_TOTAL_LIMIT:
            excess = total - settings.AI_MAPPINGS_TOTAL_LIMIT
            old_q = await db.execute(
                select(CategoryMapping)
                .where(CategoryMapping.user_id == user_id)
                .order_by(
                    CategoryMapping.weight.asc(),
                    CategoryMapping.updated_at.asc(),
                )
                .limit(excess)
            )
            for m in old_q.scalars().all():
                await db.delete(m)
            logger.warning(
                "Mapping cleanup | user=%s deleted=%s (total %s > cap %s)",
                user_id, excess, total, settings.AI_MAPPINGS_TOTAL_LIMIT,
            )
    elif existing.category_id == body.category_id:
        # Confirm — та же категория
        existing.weight += 1
        existing.updated_at = datetime.now(timezone.utc)
        logger.info("Mapping CONFIRM user=%s w=%s", user_id, existing.weight)
        logger.debug("  '%s' → '%s'", body.item_phrase, body.category_name)
    else:
        # Override — смена категории, сброс веса
        existing.category_id = body.category_id
        existing.category_name = body.category_name
        existing.weight = 1
        existing.updated_at = datetime.now(timezone.utc)
        logger.info("Mapping OVERRIDE user=%s reset w=1", user_id)
        logger.debug("  '%s' → '%s'", body.item_phrase, body.category_name)

    await db.commit()
    return {"status": "ok"}
