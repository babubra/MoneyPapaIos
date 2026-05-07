# C1 + C2: AI prompt engineering + cost & latency

> Сессия: 2026-05-06, модель: Claude Opus 4.7
> Блок плана: [`claude_code_opus_4.7_plan.md`](../claude_code_opus_4.7_plan.md) → C1 (Prompt engineering audit) + C2 (Cost & latency)
> Связанные документы: [`auth_model_C_migration.md`](../auth_model_C_migration.md) (AI trial gate), [`audit/A1_backend_surface.md`](A1_backend_surface.md) (PII в логах)

## Summary

AI-слой Monpapaios работает корректно функционально, но **стоимость и устойчивость не управляются**. Главные дыры по деньгам: на каждый запрос отправляется полный 4–5K-токеновый `SYSTEM_PROMPT` без prompt-caching; маппинги пользователя грузятся без LIMIT и растут линейно во времени; `/parse-audio` не ограничивает `max_tokens` на ответе модели; на клиенте нет retry/идемпотентности — на 502/503 пользователь тапает повторно и двойной charge. Premium-юзеры не имеют daily-cap, и поля `Device.ai_requests_today` существуют в БД, но не инкрементируются — первый же зловредный паттерн (multi-account на одном устройстве, утечка JWT) бьёт сразу по реальным токенам OpenAI.

Что работает хорошо: trial-gate выполнен правильно (`_consume_trial` после успешного AI-вызова, не до — `ai.py:108–127`); JSON-mode + retry на JSON-decode-error снижают edge-case-сбои; PII-минимизация в логах после A1-fixups закрыта.

Главное направление для C1+C2-fixups: **(1) включить prompt caching или вынести стабильную часть промпта в `cached_content` aitunnel/Gemini, (2) добавить логирование `usage`, чтобы измерять эффект, (3) поставить hard caps (max_items на схемах, LIMIT на маппинги, max_tokens на audio, daily-cap для Premium) и (4) идемпотентность на клиенте**. Сокращение текста SYSTEM_PROMPT — отдельный rabbit hole, требующий evals (см. C3).

---

## Findings

### 🔴 Critical

#### 1. Нет prompt caching — каждый AI-запрос платит за полный SYSTEM_PROMPT

**Где:** [backend/app/api/v1/ai.py:222–233](../../backend/app/api/v1/ai.py), [backend/app/core/system_prompt.py](../../backend/app/core/system_prompt.py) (200 строк, 13 705 символов)

```python
# ai.py:222-233
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
```

**Что:** SYSTEM_PROMPT — это статический 13.7KB текст (~4 000–4 500 input-токенов на современных токенайзерах). Он отправляется **один в один** на каждый `/parse` и `/parse-audio`, без `cached_content` / `prompt_cache_key` / любого другого механизма кэширования.

**Артефакт исследования:** `backend/check_cache.py:42–43` — кто-то ранее пытался читать `usage.prompt_tokens_details.cached_tokens`, но в проде ни запроса, ни логирования этого поля нет.

**Риск:** при 1 000 запросов/день в проде это ~4M input-токенов/день только на SYSTEM_PROMPT (~$0.40/день для Gemini Flash Lite, до $4/день для аналогов уровня Sonnet). Линейно растёт с DAU. Это **главный рукав утечки денег** в текущей архитектуре.

**Рекомендация (для C1+C2-fixups):** проверить, поддерживает ли aitunnel.ru `cached_content` (Gemini-style) или `prompt_cache_key` (OpenAI-style). Если не поддерживает — рассмотреть прямую интеграцию с Anthropic/OpenAI/Vertex AI (где cache cuts ≥ 75% prompt cost). Параллельно — измерить через `check_cache.py` фактический `cached_tokens` у текущего провайдера.

---

#### 2. Trial-bypass через смену аккаунта на одном устройстве — `Device.ai_requests_today` мёртвый

**Где:** [backend/app/api/v1/ai.py:82–127](../../backend/app/api/v1/ai.py) (`_check_trial`, `_consume_trial`), [backend/app/db/models.py:99–107](../../backend/app/db/models.py) (`Device.ai_requests_today`, `ai_audio_requests_hour`, `is_blocked`)

```python
# models.py:99-107
ai_requests_today: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
ai_audio_requests_hour: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
...
is_blocked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
```

**Что:** trial-gate привязан строго к `User.ai_trial_used` (`ai.py:96`). При каждом новом аккаунте (e.g. через 10minutemail.com) счётчик начинает с нуля. На одном физическом телефоне можно создать N email-аккаунтов и получить `N × AI_TRIAL_LIMIT` запросов. В `Device` модели **уже есть** счётчики, но они не инкрементируются и не проверяются нигде в коде — мёртвый код, оставшийся от device-only схемы.

**Риск:** 50 trial × $0.001 ≈ $0.05 на аккаунт. Для одного скрипт-кидди — пренебрежимо. Для бот-фермы (1 000 виртуальных аккаунтов в день) — $50/день при минимальной мотивации. Apple Sign-In, когда подключим, режет вектор естественно (1 Apple ID = 1 устройство), но до того момента это незакрытая дверь.

**Контекст в плане:** уже зафиксировано в `claude_code_opus_4.7_plan.md` → раздел «Известные issues для C2» (2026-05-06). Сейчас «выдержимо», но любая промокампания / VC-pitch-трафик мгновенно поднимает магнитуду.

**Рекомендация:** активировать `Device.ai_requests_today` как мягкий per-device daily-cap (предлагаемый порог: 30/день/устройство, считается **поверх всех `user_id`** этого `device_id`), плюс `is_blocked = true` при ≥ 6 разных `user_id` на device за сутки. UX-сообщение про device-cap должно отличаться от user-trial-cap, чтобы не путать легитимного юзера.

---

#### 3. Нет retry + нет идемпотентности на клиенте — двойной charge на 502/503/timeout

**Где:** [Monpapa/Monpapa/Services/AIService.swift:97–156](../../Monpapa/Monpapa/Services/AIService.swift) (`parseText`), [AIService.swift:160–219](../../Monpapa/Monpapa/Services/AIService.swift) (`parseAudio`), [AIService.swift:223–236](../../Monpapa/Monpapa/Services/AIService.swift) (`validateResponse`)

```swift
// AIService.swift:223-236
private func validateResponse(_ response: URLResponse, data: Data) throws {
    ...
    switch http.statusCode {
    case 200...299: return
    case 401:       throw AIServiceError.notAuthenticated
    case 402:       throw AIServiceError.paymentRequired
    case 429:       throw AIServiceError.rateLimitExceeded
    default:
        let message = (try? JSONDecoder().decode(...))?.detail ?? "Unknown error"
        throw AIServiceError.serverError(http.statusCode, message)
    }
}
```

**Что:** клиент имеет жёсткие таймауты (15s текст, 30s аудио — `AIService.swift:109,172`), но **на 502/503/timeout не делает retry/exponential backoff**. Запрос проваливается → пользователь видит ошибку → нажимает повторно. Каждый retry — отдельный billable запрос. Нет `Idempotency-Key` в headers, на бэке нет дедупликации по hash тела запроса в окне N секунд.

В связке с **отсутствием daily-cap для Premium** (см. ниже) у Premium-юзера потолка нет — bug в UI или нестабильный апстрим могут вылиться в десятки лишних вызовов на одну транзакцию.

Дополнительный угол: `_consume_trial` корректно списывает trial **только после успешного AI-вызова** (`ai.py:382–389`), что справедливо для free. Но для Premium «успех = 0 trial» = «бесконечно бесплатно» — нет ни одного механизма ограничения.

**Риск:** двойной charge при flaky network; реальные деньги на Premium. На Free — упирается в `AI_TRIAL_LIMIT=50`, поэтому magnitude ограничена, но UX страдает (юзер «съел» trial из-за нашей ретрай-стратегии).

**Рекомендация:** (а) на клиенте — exponential backoff на 502/503/timeout (max 2 ретрая, 1s/3s); (б) при retry — посылать **тот же** `Idempotency-Key` (UUID, генерируется один раз на user-action), бэк дедуплицирует в Redis/in-memory кэше на 60s; (в) добавить per-Premium daily-cap (e.g. 200 текст + 50 audio в сутки, подсчёт на User или Device).

---

#### 4. `/parse-audio` без `max_tokens` — completion может взлететь

**Где:** [backend/app/api/v1/ai.py:282–302](../../backend/app/api/v1/ai.py) (`_call_ai_audio`)

```python
# ai.py:282-302
response = await client.chat.completions.create(
    model=settings.AI_MODEL,
    messages=[
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": [...]},
    ],
    temperature=0.1,
    response_format={"type": "json_object"},
)
```

**Что:** в `_call_ai_text` стоит `max_tokens=1024` (строка 231), а в `_call_ai_audio` лимит **отсутствует**. Модель может ответить в полную длину контекста — для Gemini Flash это до 8K output-токенов.

**Риск:** «грязное» аудио (фоновый шум, длинная пауза, обрывки речи) или edge-case в промпте могут заставить модель отвечать развёрнуто (расшифровка + разбор + объяснение off-topic). Output-токены у Gemini Flash дороже input в ~3–4 раза. Один багованный запрос — не катастрофа, но при потоке audio-парсингов скрытый pacient-zero легко съест бюджет.

**Рекомендация:** `max_tokens=1024` (как в text) — этого с запасом хватает на JSON ответ согласно schema в SYSTEM_PROMPT (раздел 10).

---

#### 5. `_load_user_mappings` без LIMIT — prompt-payload растёт без потолка

**Где:** [backend/app/api/v1/ai.py:132–143](../../backend/app/api/v1/ai.py) (`_load_user_mappings`), [backend/app/db/models.py:363–388](../../backend/app/db/models.py) (`CategoryMapping`), [backend/app/api/v1/ai.py:505–557](../../backend/app/api/v1/ai.py) (`/mapping` upsert без верхней границы)

```python
# ai.py:132-143
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
```

**Что:** при каждом `/parse` загружаются **ВСЕ** маппинги пользователя (без LIMIT, без пагинации). В `build_ai_prompt` (`system_prompt.py:184–188`) каждый маппинг становится строкой ~60 символов и идёт в prompt. Эндпоинт `POST /mapping` (`ai.py:505+`) делает upsert без проверки общего количества маппингов на юзера, без cleanup по `weight=1, updated_at < 6 месяцев`.

**Риск:** активный пользователь с привычкой подтверждать категории через 1 год = 500–1000 маппингов = +30–60K дополнительных символов промпта (~10–20K токенов лишних) **на каждый запрос**. Это худшая характеристика «деньги растут с loyalty»: чем дольше пользователь с нами, тем дороже его обслуживание. Плюс модели начинают «тонуть» в ленте маппингов (instruction following degrades), что ухудшает качество.

В schema SYSTEM_PROMPT раздел «User Category Preferences (HIGHEST PRIORITY)» (system_prompt.py:38–42) усиливает эффект: модель обязана сканировать весь список на каждый запрос.

**Рекомендация:** (а) `_load_user_mappings`: `LIMIT settings.AI_MAPPINGS_PROMPT_LIMIT` (предлагаемый дефолт 30, уже сортировка по weight — берём топ); (б) `/mapping`: при upsert проверять total count, при > 200 на юзера — удалять самый старый/слабый по weight; (в) логировать `len(mappings)` на INFO, чтобы видеть распределение в проде.

---

> **Дополнение:** Critical-секция намеренно сфокусирована на «горящих деньгах». Качество AI-ответов (галлюцинации, off-topic, точность mapping-преференций) — отдельный блок [C3](../claude_code_opus_4.7_plan.md) и не оценивается здесь.

### 🟡 Medium

#### 6. Нет логирования `usage.prompt_tokens / completion_tokens / cached_tokens` — слепота по стоимости

**Где:** [backend/app/api/v1/ai.py:204–266](../../backend/app/api/v1/ai.py), [backend/app/api/v1/ai.py:268–326](../../backend/app/api/v1/ai.py)

**Что:** OpenAI SDK возвращает `response.usage` после каждого вызова — там `prompt_tokens`, `completion_tokens`, и (если провайдер поддерживает prompt-caching) `prompt_tokens_details.cached_tokens`. В `_call_ai_text` / `_call_ai_audio` объект `usage` **никогда не извлекается и не логируется**. Эти поля даже не попадают в DEBUG-лог. Грепом по `backend/app/`: `usage`, `prompt_tokens`, `completion_tokens`, `cached_tokens` — нет ни одного матча.

**Риск:** мы не знаем фактическую стоимость в проде. Сравнить «до/после» любой оптимизации (Critical #1, #4, #5) можно будет только через биллинг aitunnel. Невозможно построить алерт на cost-anomaly (внезапный спайк по одному пользователю).

**Рекомендация:** `logger.info("AI usage | model=%s prompt=%d completion=%d cached=%d", ...)` после каждого вызова. Параллельно — складывать суммы в `User.ai_tokens_used_total` (или агрегированную дневную таблицу), чтобы можно было быстро найти top-N тяжёлых юзеров. Особенно важно при включении prompt-cache — без логирования неясно, действительно ли кэш срабатывает.

---

#### 7. Pydantic-схемы без `max_items` + клиент шлёт все категории без фильтрации

**Где:** [backend/app/schemas.py:26–31](../../backend/app/schemas.py) (`ParseTextRequest`), [Monpapa/Monpapa/Views/DashboardView.swift:65–74](../../Monpapa/Monpapa/Views/DashboardView.swift) (`aiCategoryDTOs`)

```python
# schemas.py:26-31
class ParseTextRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=500)
    categories: list[CategoryContext] = Field(default_factory=list)
    counterparts: list[CounterpartContext] = Field(default_factory=list)
    locale: str = Field(default="ru", max_length=5, ...)
```

**Что:** на `text` есть `max_length=500`, но на списки `categories` / `counterparts` валидации **нет**: можно прислать массив из 10 000 элементов, и каждый попадёт в prompt через `build_ai_prompt` (`system_prompt.py:176–194`). На клиенте (`DashboardView.swift:65–74`) — `aiCategoryDTOs` отдаёт все категории пользователя «как есть»: ни active-only, ни недавно использованные, ни top-N.

**Риск:** доброкачественный — типичный пользователь с 30 категориями платит +1.5KB в каждом запросе. Зловредный (или с багом) — зашлёт 10K элементов и съест полный context-window модели. DoS-вектор для AI-токенов: 100 запросов × 100K токенов промпта = быстрая утечка бюджета.

**Рекомендация:** (а) `categories: list[...] = Field(default_factory=list, max_length=200)`, аналогично для `counterparts`; (б) на клиенте — фильтровать по «недавно использованные» / `is_active=true` / top-N (40–50 будет с запасом для большинства юзеров); (в) при `len > N` бэк может **обрезать** (с логом WARNING), а не ронять запрос — UX важен.

---

#### 8. Нет локального кэша AI-ответов на клиенте

**Где:** [Monpapa/Monpapa/Services/AIService.swift](../../Monpapa/Monpapa/Services/AIService.swift) (полный файл — кэш не реализован)

**Что:** одинаковые входы шлются на сервер заново. «купил хлеб 100», «зарплата 50000» — детерминированные строки, но `parseText` не использует ни `URLCache`, ни `NSCache`, ни in-memory dictionary. Каждый ввод = новый billable вызов.

**Риск:** пользователь поправил опечатку → отменил → ввёл ту же фразу → второй вызов. В голосовом флоу retap микрофона при плохом распознавании = повторная отправка близких аудио. На длинном горизонте это 5–15% избыточных вызовов (грубая оценка, реальное число нужно мерить через usage-логи из M6).

**Рекомендация:** in-memory LRU-кэш на (text + locale + categories.signature + mappings_version) → `AiParseResult`, TTL 5–10 минут, размер 50 элементов. Аудио — кэшировать по hash файла (SHA-256 первых 1MB достаточно). Bonus: при cache hit показать «(cached)» в логе и метрике.

---

#### 9. `response_format={"type": "json_object"}` вместо `json_schema`

**Где:** [backend/app/api/v1/ai.py:232](../../backend/app/api/v1/ai.py), [backend/app/api/v1/ai.py:301](../../backend/app/api/v1/ai.py)

**Что:** обе функции используют свободный `json_object`-режим, что не гарантирует структуру. Модель может вернуть JSON с лишним полем, пропуском обязательного, или со строкой "null" вместо настоящего null (для этого есть `_normalize_null_strings` — `ai.py:154–171` — отдельный workaround). Современные провайдеры (Gemini 2.0, gpt-4o-2024-08-06+, Claude 3.5+) поддерживают **строгий `response_format=json_schema`** с гарантированной валидностью схемы.

**Риск:** retry на JSON-decode-error (`ai.py:241–248`) сжигает токены при сломанном ответе (платим дважды); раздел SYSTEM_PROMPT 4b «JSON null vs string (CRITICAL)» (system_prompt.py:33–37) и блоки `# 10. JSON Schema` (system_prompt.py:117–125) — фактически «учим модель руками тому, что должен делать json_schema».

**Рекомендация:** проверить, поддерживает ли aitunnel передачу `response_format={"type":"json_schema","json_schema":{...}}`. Если да — описать схему один раз в Pydantic → сгенерировать из неё JSON Schema → передать в API; убрать секции 4b и 10 из SYSTEM_PROMPT (это даст также экономию ~1.5KB в промпте). Если aitunnel не пропускает — рассматривать как ещё один аргумент в пользу прямой интеграции с провайдером (см. Critical #1).

---

#### 10. `AI_MAX_AUDIO_SECONDS` (30s) задан в конфиге, но не валидируется

**Где:** [backend/app/core/config.py:39](../../backend/app/core/config.py), [backend/app/api/v1/ai.py:404–453](../../backend/app/api/v1/ai.py) (`/parse-audio` — нет проверки длительности)

**Что:** `AI_MAX_AUDIO_SECONDS: int = 30` определён, но в `parse_audio` валидируется **только размер в байтах** (`_MAX_AUDIO_BYTES = 5MB`, `ai.py:439–443`). 5 минут речи в AAC 16kHz моно умещаются в 5MB. На клиенте `AudioRecorderService.maxActiveSpeech: TimeInterval = 30.0` (`AudioRecorderService.swift:63`), но это ограничение **только клиента** — кто-то, кто бьёт API напрямую (или модифицированный клиент), может прислать 5-минутный файл.

**Риск:** длинное аудио = больше input-токенов на multimodal-модели + большая вероятность развёрнутого ответа. Аудио стоит дороже, чем кажется: ~25 input-токенов/секунду на Gemini Flash multimodal — 5-минутный файл ≈ 7 500 input-токенов **только за аудио** (плюс SYSTEM_PROMPT).

**Рекомендация:** на бэке после `audio.read()` — распарсить заголовок AAC/WAV (через `mutagen` или `ffprobe`), проверить duration, отбить 413 / 422 при `> AI_MAX_AUDIO_SECONDS`. Альтернатива побыстрее — оценочный расчёт «секунды ≈ size_bytes / 4000» (для AAC 16kHz моно) и отказ при `> 35s` без распарса.

---

#### 11. AAC `AVAudioQuality.high` для речи 16kHz — переплата по размеру/токенам

**Где:** [Monpapa/Monpapa/Services/AudioRecorderService.swift:117–122](../../Monpapa/Monpapa/Services/AudioRecorderService.swift)

```swift
// AudioRecorderService.swift:117-122
let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
]
```

**Что:** `AVAudioQuality.high` (.medium / .high / .max) для голоса в 16kHz моно — overkill. Speech recognition не различает `.medium` и `.high` на коротких диалоговых записях (по нашему профилю — 5–30 секунд). `.medium` снижает bitrate с ~96 kbps до ~64 kbps, размер падает на ~30%.

**Риск:** не критичный, но multimodal-модели часто берут плату по байтам аудио (через эквивалент input-токенов). 30% × 1000 запросов/день = реальные деньги при масштабе.

**Рекомендация:** заменить на `AVAudioQuality.medium`. Дополнительно можно перейти на `AVSampleRateKey: 16000` + Opus (`kAudioFormatOpus`) — Opus при таком же качестве даёт ещё ~30% выигрыш по размеру, но требует проверки совместимости с aitunnel/Gemini multimodal API (m4a гарантированно поддерживается, opus — не везде).

---

#### 12. `sendMapping` fire-and-forget без persistence — теряем auto-learn-данные при offline

**Где:** [Monpapa/Monpapa/Services/AIService.swift:344–376](../../Monpapa/Monpapa/Services/AIService.swift)

```swift
// AIService.swift:369-375
do {
    let (data, _) = try await URLSession.shared.data(for: request)
    ...
} catch {
    MPLog.autolearn.error("⚠️ sendMapping ошибка: \(error.localizedDescription, privacy: .public)")
}
```

**Что:** при сетевой ошибке маппинг просто логируется и теряется. Нет очереди для повтора при восстановлении сети. Маппинги — ценнейший сигнал персонализации (раздел 5 SYSTEM_PROMPT, «HIGHEST PRIORITY»), и в офлайн-флоу они не должны пропадать. Тип `is_override=true` особенно жалко терять — это явный фидбек юзера о неправильной автокатегоризации.

**Риск:** не cost, а quality — auto-learn деградирует, юзер заново выбирает категорию для тех же товаров → лишние клики и (косвенно) больше AI-вызовов на «исправлениях».

**Рекомендация:** очередь в SwiftData (или UserDefaults JSON-список) — `[(item_phrase, category_id, category_name, is_override, created_at)]`. При запуске приложения и восстановлении сети — flush очереди в `/mapping` (или дополнить новый эндпоинт `POST /mapping/batch`). Дедупликация по `(item_phrase + category_id)`.

---

#### 13. SYSTEM_PROMPT можно сократить ≈ на 30–40% без потери качества

**Где:** [backend/app/core/system_prompt.py:1–126](../../backend/app/core/system_prompt.py)

**Что:** 13.7K-символьный SYSTEM_PROMPT содержит избыточность:
- Раздел 4b «JSON null vs string» (system_prompt.py:33–37) — мог бы быть закрыт `json_schema` (см. M9).
- Раздел 8 «Debt Parsing» (system_prompt.py:71–109) — 9 примеров повторяют одну и ту же логику для inbound/outbound.
- Раздел 10 «JSON Schema» (system_prompt.py:117–125) — три практически одинаковых JSON-объекта (transactions / new debts / debt payments) различаются 2–3 полями.
- Дубликаты «CRITICAL» / «IMPORTANT» / «(REQUIRED in response)» в маркерах раздаются по-русски «громче, значит лучше» — реальные модели на эти эмоции не реагируют.

**Риск:** оптимизировать promptlen напрямую в input-токены: ~40% × 4 500 ≈ 1 800 токенов экономии на каждый запрос. Если prompt-cache **не** работает (Critical #1), это даёт прямую экономию. Если работает — экономия только на cold path, но все ещё имеет смысл (особенно через json_schema).

**Внимание:** сокращение SYSTEM_PROMPT **обязано** быть оценено через evals (раздел 9 SYSTEM_PROMPT — Localization, raздел 5 — User Preferences особенно чувствительны). Это вход в C3, не в C2.

**Рекомендация:** в C1+C2-fixups — **только подготовить eval-набор** (10–20 примеров на основе real-юзер-логов, ground truth для type/amount/category), но **не сокращать промпт** до его наличия. Сокращение делать в C3.

---

#### 14. Нет per-locale evals — backend/tests/ отсутствует

**Где:** `backend/tests/` (директория не существует)

**Что:** нет автоматических тестов вообще, ни для AI-парсинга, ни для других эндпоинтов. SYSTEM_PROMPT поддерживает 12 локалей (system_prompt.py:130–143), но мы полагаемся исключительно на reasoning-способности Gemini для en/de/fr/es/it/pt/tr/zh/ja/ko/ar. Любая регрессия (новый промпт, смена модели, обновление aitunnel) обнаружится **только в проде через юзер-репорты**.

**Риск:** ошибки парсинга в редких локалях → юзер тратит больше AI-запросов на «исправления» через переотправку → деньги. Хуже — бесшумные регрессии после смены AI_MODEL.

**Рекомендация:** структурный pytest `backend/tests/test_ai_parse.py` с фикстурами:
- по 5–10 примеров текста на ru/en (минимум) с ground-truth `{type, amount, currency, item_phrase, category_match}`
- мок aitunnel (через `respx` / `httpx_mock`) — НЕ бить в реальный API в CI
- параллельно — `backend/tests/golden/` с реальными запросами к aitunnel за фиксированную плату (запускается только локально на смене промпта или модели)

Это, опять же, в первую очередь задача C3, но без минимальной test-инфраструктуры C1+C2-fixups невозможно безопасно деплоить.

---

#### 15. Premium-юзеры без daily-cap — `_check_trial` пропускает их полностью

**Где:** [backend/app/api/v1/ai.py:82–105](../../backend/app/api/v1/ai.py)

```python
# ai.py:93-94
if _is_premium(user):
    return  # ← никаких других ограничений
```

**Что:** для Premium-юзеров `_check_trial` мгновенно возвращается без какой-либо проверки счётчиков. В `User` нет полей вроде `ai_requests_today`, `ai_audio_requests_hour` (они есть только в `Device` и не используются — см. Critical #2). Безлимит = реальный безлимит.

**Риск:** комбинация с Critical #3 (нет retry/idempotency) даёт самый быстрый путь к утечке: один зловредный/багованный клиент с украденным Premium-JWT может за час слить десятки долларов токенов. Даже без злоумышленника — bug в UI-цикле (бесконечный авто-retry на ошибке) бьёт по деньгам напрямую.

**Рекомендация:** добавить per-Premium daily-cap (e.g. `User.ai_requests_today` + `ai_requests_reset_at`), мягкий потолок 200 текст + 50 audio в сутки. При превышении — 429 с понятным сообщением «Достигнут лимит на сутки, лимит обнулится через X часов». Premium-юзеры реальные не заметят, но safety-net получим. Эта рекомендация технически дублирует C2-finding из плана: «нет per-user daily-cap для Premium».

---

### 🟢 Low / Nice-to-have

#### 16. `temperature=0.1` для JSON-парсинга — лучше 0

**Где:** [backend/app/api/v1/ai.py:230](../../backend/app/api/v1/ai.py), [backend/app/api/v1/ai.py:300](../../backend/app/api/v1/ai.py)

**Что:** для детерминированного парсинга финансовых транзакций оптимально `temperature=0` (greedy decoding). При `0.1` всё ещё есть мелкая стохастика — два одинаковых запроса могут давать чуть разные `category_name` или `item_phrase`, что мешает stability-тестам и косвенно — кэшированию.

**Рекомендация:** `temperature=0` в обеих функциях. Замерить через evals (M14) разницу в качестве — обычно нулевая или положительная.

---

#### 17. `AI_RATE_LIMIT_DAILY` / `AI_RATE_LIMIT_AUDIO_HOURLY` — мёртвый конфиг

**Где:** [backend/app/core/config.py:36–37](../../backend/app/core/config.py)

```python
AI_RATE_LIMIT_DAILY: int = 50
AI_RATE_LIMIT_AUDIO_HOURLY: int = 5
```

**Что:** эти переменные остались от device-only схемы (до Auth Model C). После миграции на user-JWT они не используются нигде в коде (grep подтверждает). Комментарий в `config.py:35` это признаёт. Аналогично `RateLimitInfo` в `schemas.py:34–38` — определена, но эндпоинт `/auth/device` удалён.

**Риск:** misleading config — новый разработчик подумает, что rate-limit активен.

**Рекомендация:** удалить из `config.py`, `.env.example`, `schemas.py`. Если будут переиспользоваться для M15 (Premium daily-cap) — переименовать в `PREMIUM_DAILY_CAP_TEXT` / `PREMIUM_DAILY_CAP_AUDIO` с ясной семантикой.

---

#### 18. UNIQUE `(user_id, item_phrase)` задокументирован, но не реализован

**Где:** [backend/app/db/models.py:363–388](../../backend/app/db/models.py) (`CategoryMapping`), [backend/app/api/v1/ai.py:520–527](../../backend/app/api/v1/ai.py) (lookup без UNIQUE гарантии)

**Что:** в docstring `CategoryMapping` (models.py:368) написано про UNIQUE-ограничение, но в коде есть только `Index` на `user_id` (строка 377). На уровне БД ничего не запрещает создать два маппинга с одной парой `(user_id, item_phrase_lower)`. Параллельные запросы `POST /mapping` от одного пользователя в гонке создадут дубли.

**Риск:** дубли искажают `weight`-логику и раздувают prompt-payload (Critical #5). Маловероятно в реальной жизни (два устройства одновременно подтверждают одну категорию), но возможно при retry-тапах.

**Рекомендация:** добавить `UniqueConstraint("user_id", "item_phrase_lower", name="uq_category_mappings_user_phrase")` (с `item_phrase_lower` как computed/index column). При следующем рефакторе БД (D1, Alembic baseline) — заодно почистить дубли через `DELETE ... WHERE row_number() > 1`.

---

#### 19. `_sanitize_json` режет `//` внутри строк (включая URL)

**Где:** [backend/app/api/v1/ai.py:194–195](../../backend/app/api/v1/ai.py)

```python
# Убираем однострочные комментарии (// ...)
text = re.sub(r'//[^\n]*', '', text)
```

**Что:** регекс не различает `//` в комментарии и `//` внутри строкового значения JSON. Если AI вернёт `{"raw_text": "https://example.com/payment"}` (например, юзер скопипастил ссылку), sanitize всё, что после `//`, превратит в `{"raw_text": "https:` → невалидный JSON → отправляется на retry → лишние токены.

**Риск:** редкий, но возможный edge-case. Обычно AI возвращает не URL, но юзер может прописать ссылку в `item_phrase` или диктовать «оплатил подписку через https://...».

**Рекомендация:** sanitize вызывается **только если** `json.loads(text)` уже упал. Если упал — попробовать сначала **без** комментариев-stripping (только trailing comma fix + markdown unwrap), и только если опять не парсится — резать `//`. Альтернатива — proper JSON-aware tokenizer (но overkill).

---

#### 20. OpenAI-клиент создан без `timeout` — запросы могут висеть

**Где:** [backend/app/main.py:34–37](../../backend/app/main.py)

```python
app.state.ai_client = AsyncOpenAI(
    api_key=app_settings.AITUNNEL_API_KEY,
    base_url=app_settings.AITUNNEL_BASE_URL,
)
```

**Что:** `AsyncOpenAI` создаётся без `timeout=...`. SDK по умолчанию использует 600s. На клиенте таймаут 15s/30s, поэтому пользователь увидит ошибку, **но запрос на бэке продолжит выполняться** (FastAPI без cancel-on-disconnect ждёт завершения). При flaky aitunnel это значит: процесс держит TCP-сокет, потребляет worker-slot, и всё ещё может списать токены OpenAI/Gemini, хотя ответ уже никому не нужен.

**Риск:** worker exhaustion при медленном апстриме + лишние токены за «зомби»-запросы.

**Рекомендация:** `AsyncOpenAI(..., timeout=httpx.Timeout(connect=5.0, read=20.0, write=10.0, pool=2.0))`. Дополнительно — middleware `cancel_on_disconnect` (FastAPI starlette) или явный `asyncio.wait_for(...)` в `_call_ai_*`.

---

#### 21. Locale, не входящий в `_LOCALE_MAP`, попадает в промпт сырой строкой

**Где:** [backend/app/core/system_prompt.py:170](../../backend/app/core/system_prompt.py)

```python
lang_name = _LOCALE_MAP.get(locale, locale)
parts.append(f"Target locale for translations: {lang_name}")
```

**Что:** если клиент передал `locale="xx"` (опечатка или неизвестная локаль) — в промпт уйдёт строка `Target locale for translations: xx`, и Gemini попытается «угадать», а реальный пользователь получит непредсказуемый локализованный ответ.

**Риск:** UX-баг (а не cost), но иногда модель реагирует на «xx» отказом отвечать → юзер шлёт запрос ещё раз = ещё токены.

**Рекомендация:** в `ParseTextRequest.locale` (`schemas.py:31`) добавить `pattern=r"^(ru|en|de|fr|es|it|pt|tr|zh|ja|ko|ar)$"` — отбивать на уровне валидации с понятной ошибкой 422.

---

## Что не покрыли

- **C3 (качество AI-ответов)** — отдельный блок плана: галлюцинации, точность off-topic detection, accuracy mapping-преференций, evals по локалям. Без минимальной тестовой инфраструктуры (M14) C3 будет subjective. Рекомендуется делать C3 сразу после C1+C2-fixups, чтобы измерить эффект изменений.
- **Реальные cost-замеры** — `check_cache.py` нужно прогнать вручную против текущего `AI_MODEL=gemini-3.1-flash-lite-preview` через aitunnel.ru, чтобы зафиксировать `prompt_tokens` / `cached_tokens` baseline. Без этого числа любые claims про «X% экономии» — теоретические. Это первое action-item для C1+C2-fixups.
- **A/B по моделям** — gemini-3.1-flash-lite-preview vs gemini-2.0-flash vs gpt-4o-mini vs claude-3.5-haiku. Цена/качество могут радикально отличаться, особенно для multimodal-аудио. Без evals (M14) сравнение бессмысленно.
- **Поведение aitunnel.ru** — поддерживает ли провайдер `cached_content` (Gemini), `prompt_cache_key` (OpenAI), `response_format=json_schema`, передачу `tools`/`function_calling`. Нужно прочитать актуальную доку aitunnel или проверить эмпирически. От этого ответа зависит реализация Critical #1 и Medium #9.
- **Concurrency safety на `User.ai_trial_used += 1`** — два параллельных `/parse` от одного юзера могут оба пройти `_check_trial` (юзер на 49/50), оба отработать, оба вызвать `+= 1` без `SELECT ... FOR UPDATE`. На SQLAlchemy default-isolation level (READ COMMITTED) lost-update возможен. Проблема смежная с A2/A3 (data layer + auth), но касается и денег.
- **Streaming** — `stream=True` не используется. Для UX это могло бы сократить «время до первого токена» для голосовых сценариев, но требует переписывания клиента и обработки partial-JSON. Не критично; решается после base-оптимизаций.
- **Quotas alerts / cost dashboard** — мониторинг расходов, алерты на cost-anomaly per-user (e.g. ≥ 10× от p50 за час). Это блок **D2 (Observability)**, упомянуть только что без M6 (usage-логирования) D2 не построится.
- **Frontend B-блок** — UX trial-strip / paywall sequence, ререндеры списка категорий в `aiCategoryDTOs`, debounce на ввод в `AIInputBar`. Это блоки B1/B2/B3 и не оцениваются здесь.
- **Безопасность multipart-парсинга на `/parse-audio`** — в A1-fixups закрыты MIME whitelist + size limit, но не покрыт payload validity (поддельный m4a header с другим content). Малая магнитуда, но строго говоря — open question.

---

## Сводная таблица для C1+C2-fixups

| ID | Severity | Кратко | Файл |
|----|----------|--------|------|
| 1  | 🔴 | Нет prompt caching | `ai.py:222-233`, `system_prompt.py` |
| 2  | 🔴 | Trial-bypass + Device.ai_requests_today мёртвый | `ai.py:82-127`, `models.py:99-107` |
| 3  | 🔴 | Нет retry/идемпотентности на клиенте | `AIService.swift:109,172,223-236` |
| 4  | ✅ 🔴 | `/parse-audio` без `max_tokens` (закрыт 2026-05-07) | `ai.py:282-302` |
| 5  | ✅ 🔴 | `_load_user_mappings` без LIMIT (закрыт 2026-05-07: prompt-LIMIT=30, total-cap=200, cleanup в upsert) | `ai.py:132-143`, `models.py:363-388` |
| 6  | ✅ 🟡 | Нет логирования `usage` tokens (закрыт 2026-05-07, M6) | `ai.py:204-326` |
| 7  | ✅ 🟡 | Pydantic без `max_items` + клиент шлёт все категории (закрыт 2026-05-07: max_length=200 + top-50 на клиенте) | `schemas.py:26-31`, `DashboardView.swift:65-74` |
| 8  | 🟡 | Нет client-cache AI-ответов | `AIService.swift` |
| 9  | 🟡 | `json_object` вместо `json_schema` | `ai.py:232,301` |
| 10 | 🟡 | `AI_MAX_AUDIO_SECONDS` не валидируется | `ai.py:404-453`, `config.py:39` |
| 11 | 🟡 | AAC `AVAudioQuality.high` для речи | `AudioRecorderService.swift:117-122` |
| 12 | 🟡 | `sendMapping` fire-and-forget без persistence | `AIService.swift:344-376` |
| 13 | 🟡 | SYSTEM_PROMPT redundancy ~30-40% | `system_prompt.py:1-126` |
| 14 | 🟡 | Нет per-locale evals + нет тестов | `backend/tests/` (отсутствует) |
| 15 | 🟡 | Premium без daily-cap | `ai.py:82-105` |
| 16 | ✅ 🟢 | `temperature=0.1` → 0 (закрыт 2026-05-07: в обоих парсерах, эмпирически проверено лучшее качество на ru) | `ai.py:230,300` |
| 17 | 🟢 | `AI_RATE_LIMIT_*` мёртвый конфиг | `config.py:36-37` |
| 18 | 🟢 | UNIQUE `(user_id, item_phrase)` не реализован | `models.py:363-388` |
| 19 | 🟢 | `_sanitize_json` режет `//` в URL | `ai.py:194-195` |
| 20 | 🟢 | OpenAI-клиент без `timeout` | `main.py:34-37` |
| 21 | 🟢 | Locale fallback в промпт сырой | `system_prompt.py:170`, `schemas.py:31` |

**Итого:** 5 🔴 / 10 🟡 / 6 🟢. Рекомендуемый порядок C1+C2-fixups: M6 (usage-логирование, чтобы измерить baseline) → C3-евал-инфраструктура (M14, минимум 10 примеров) → C1.4, C1.5, C2.10 (быстрые caps по 1 строке) → C1.1, C1.3 (структурные правки) → остальное.

**Статус закрытия (по сессиям):**
- 2026-05-07: ✅ #6 (M6 — usage-логирование).
- 2026-05-07: ✅ #4, #5, #7 — быстрые caps (audit/C1_C2_baseline.md → todo). Verified curl-сценариями: 201 cats → 422, 200 cats → 200; mappings count=30/30; cleanup `total > cap → deleted`. iOS-сторона #7 (top-50 фильтр в `DashboardView.aiCategoryDTOs`) — собирается следующим Xcode-build'ом.
- 2026-05-07: ✅ #16 — `temperature=0` в обоих парсерах. Юзер эмпирически проверил, что на `gemini-2.5-flash-lite` это даёт лучшее качество на ru-кейсах + устраняет стохастику между идентичными запросами. Verified: два одинаковых `/parse` → идентичный JSON.
- Открыто: #1, #2, #3, #8-#15, #17-#21. Дальше по приоритету: **M14** (eval-набор) → **M13** (promptlen) → **#1** (prompt caching) → **#3** (retry/idemp) → **#15** (Premium cap) → остальное.
