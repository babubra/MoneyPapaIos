# MonPapa — План оптимизации AI-распознавания транзакций

> Цель: снизить стоимость токенов и latency, повысить устойчивость распознавания,
> не ломая текущий API-контракт `/api/v1/ai/parse`.
> Составлен 23 апреля 2026.

---

## 🎯 Цели и метрики

**Что оптимизируем:**
1. Input-токены на один вызов LLM (сейчас ~1500–3000 токенов при 50 категориях).
2. Количество вызовов LLM на успешный парс (цель: ≤1 в 95% случаев).
3. Устойчивость: уменьшить долю `status != "ok"` и битого JSON.

**Метрики для оценки (логировать в `logger.info`):**
- `prompt_tokens`, `completion_tokens` из `response.usage` (OpenAI SDK их отдаёт).
- Флаг `retry_count` (0 если попал с первого раза).
- Флаг `hard_hit` (категория определена детерминированно, без LLM-решения).
- Время ответа endpoint'а (от входа до return).

**Baseline (замерить ДО начала работы):**
Прогнать ~20 реальных текстов через текущую реализацию, записать среднее по трём метрикам — это benchmark, с которым сравниваем каждую фазу.

---

## 🏛 Архитектурные принципы

1. **Не ломать контракт**: форма `ParseTextRequest` и формат ответа не меняются. iOS-клиент не должен знать о внутренних оптимизациях.
2. **Фичефлаги**: каждую оптимизацию включать через настройку в `app/core/config.py` (`AI_ENABLE_*`), чтобы можно было откатить без деплоя кода.
3. **Фаллбэк всегда**: если эвристика не сработала — собираем промт как раньше, полный. Хуже не станет.
4. **Логирование до/после**: каждая фаза добавляет 1–2 поля в лог, чтобы измерять эффект.
5. **Атомарность фаз**: каждую фазу можно катить в прод отдельно и независимо откатывать.

---

## 📋 Фаза 0 — Hotfix-стабилизация (журнал правок по ходу тестов)

> Сюда записываем точечные фиксы, обнаруженные во время ручного тестирования.
> Это не оптимизация, а устранение корневых багов, которые иначе исказят замеры Фаз 1–6.

### 0.1. Нормализация строковых `"null"` в ответе AI ✅ 2026-04-23
**Проблема:** на запрос «Починил велосипед 800 рублей» Gemini вернул `"category_id":"null"`, `"category_name":"null"` (строковые литералы), iOS показал категорию с именем «null».
**Фикс:**
- `backend/app/api/v1/ai.py` — подключена `_normalize_null_strings` ко всем точкам декода JSON (`_call_ai_text` обе ветки + `_call_ai_audio`). До этого функция существовала, но не вызывалась.
- `backend/app/core/system_prompt.py` — новая секция **§4b** с явным требованием не квотить `null`; усилено §4 — при `category_is_new=true` имя обязано быть непустым.
- `Monpapa/Views/AddTransactionSheet.swift` — defense-in-depth: `applyPrefill` отфильтровывает `""`, `"null"`, `"none"`.
**Релевантно Фазе 6:** эта же логика должна стать частью `validate_ai_response` (валидатор будет отклонять `"null"`-строки и триггерить semantic retry).

### 0.2. ⚠️ iOS не передаёт контрагентов в AI — КРИТИЧНО для Фаз 3, 4, 6
**Проблема:** `AIInputBar.sendText` и `sendVoice` вызывают `parseText(trimmed, categories: categories)` без параметра `counterparts` (`Monpapa/Components/AIInputBar.swift:307, 367`). В `DashboardView` формируется `aiCategoryDTOs`, но `aiCounterpartDTOs` нет вовсе. В промт на бэкенде уходит `No counterparts yet.` — §7 system_prompt (fuzzy-матч Серёжа=Сергей, дательный падеж, перестановка Ф+И) никогда не срабатывает. AI каждый раз создаёт «нового» контрагента с `counterpart_is_new=true`.
**Последствия для плана:**
- Фаза 4 («gating контрагентов») бесполезна, пока контрагенты вообще не доходят до сервера.
- Любой замер качества debt-парсинга в Фазе 7 будет заниженным.
**Действие:** починить ДО Фазы 1 (добавить `aiCounterpartDTOs` в `DashboardView`, прокинуть через `AIInputBar` → `AIService.parseText/parseAudio`). Статус: **TODO**.

### 0.3. ⚠️ iOS игнорирует `result.currency` от AI
**Проблема:** `AddTransactionSheet.saveTransaction` сохраняет `settings.defaultCurrency` независимо от того, что вернул AI (`Monpapa/Views/AddTransactionSheet.swift:615`). Если пользователь скажет «купил кофе $3», AI корректно распознает `currency=USD`, но запишется RUB.
**Действие:** использовать `result.currency` при наличии. Статус: **TODO** (не блокирует план оптимизации, но искажает метрики качества).

### 0.4. ⚠️ Поиск существующей категории на iOS только по имени
**Проблема:** `applyPrefill` игнорирует `result.categoryId` и матчит по `name.lowercased()` (`Monpapa/Views/AddTransactionSheet.swift:523`). Если AI вернёт id, но имя в локализации/капитализации отличается — матча не будет, категория продублируется с `aiSuggestedCategoryName`.
**Действие:** при наличии `categoryId` — сначала матчить по `clientId`, потом fallback на имя. Статус: **TODO**.

### 0.6. Миграция `print` → `os.Logger` (AI-флоу) ✅ 2026-04-23
**Зачем:** `print` под `#if DEBUG` невидим в TestFlight/Release, нет уровней, нет фильтрации, нет persistence. Для замеров Фазы 1 и отладки у реальных юзеров нужен Apple Unified Logging.
**Сделано:**
- `Monpapa/Services/MPLogger.swift` (новый) — единая точка: subsystem `com.monpapa.ai`, категории `service` / `input` / `dashboard` / `prefill` / `autolearn` / `auth`.
- Мигрированы все логи AI-флоу:
  - `AIService.swift` — `MPLog.service` / `.auth` / `.autolearn`, уровни `debug` (тяжёлые дампы: body JSON, response body, raw text) / `info` (жизненный цикл: 📤/📥/✅) / `notice` (401, rateLimit skip) / `error` (сеть, декод, DecodingError с codingPath).
  - `AIInputBar.swift` — `MPLog.input`.
  - `DashboardView.swift` (`handleAIResult`/`handleDebtPayment`) — `MPLog.dashboard`.
  - `AddTransactionSheet.swift` (`applyPrefill`/`saveTransaction`/auto-learn) — `MPLog.prefill` / `.autolearn`.
  - `AddDebtSheet.swift` (`applyPrefill`/`save`/`resolveCounterpart`) — `MPLog.prefill`.
- Удалены все `#if DEBUG` в логике AI-флоу — `Logger` ленив сам.
- Строковые параметры явно помечены `privacy: .public` — иначе маскируются как `<private>` в Release.
**Не мигрировано (вне AI-флоу, отложено):**
- `SyncService.swift` (18 `print`), `AuthService.swift` (17), `AuthCoverView.swift` (12), `WelcomeView.swift` (2), `KeychainService.swift` (1), `AddPaymentSheet.swift` (1), `CreateCategoryView.swift` (1). Мигрировать при ревизии соответствующих модулей.
**Фильтрация логов:**
- В Console.app на Mac: `subsystem:com.monpapa.ai category:service` или просто `subsystem:com.monpapa.ai`.
- В терминале: `log stream --predicate 'subsystem == "com.monpapa.ai"' --level debug`.
- В release-сборке `.debug` не показывается по умолчанию — включается через `log config --mode "level:debug" --subsystem com.monpapa.ai`.

### 0.5. ⚠️ Auto-learn mapping отправляется только если категория выбрана
**Проблема:** `sendMapping` вызывается при `categoryToSave != nil` (`Monpapa/Views/AddTransactionSheet.swift:588-590`). Если юзер сохранил транзакцию без категории (что разрешено) — обучения нет, Фаза 5 (hard-hit по mappings) теряет данные.
**Действие:** решить продуктово — или запрещать сохранение без категории, или отправлять negative-mapping. Статус: обсудить с продактом.

---

## 📋 Фаза 1 — Базовая инструментация (замеры)

**Зачем:** без замеров нельзя оценить эффект.

**Файлы:**
- `backend/app/api/v1/ai.py`

**Задачи:**
1. В `_call_ai_text` и `_call_ai_audio` прочитать `response.usage.prompt_tokens`, `completion_tokens`, `total_tokens`.
2. Добавить в `logger.info` строку вида: `📊 tokens: prompt=X completion=Y total=Z retries=N`.
3. Вернуть в dict результата скрытое служебное поле `_meta: {prompt_tokens, completion_tokens, retries}` — **не отдавать клиенту** (срезать перед `return` в endpoint'ах). Или писать только в лог.
4. В `parse_text` замерить длительность: `start = time.perf_counter()` → лог после `_call_ai_text`.

**Acceptance criteria:**
- В логах каждого успешного запроса видны токены и время.
- Написать ad-hoc скрипт `backend/scripts/ai_benchmark.py`, который гонит список тестовых фраз через endpoint и печатает таблицу (avg tokens, avg time, success rate).

**Тесты:**
- Ручной прогон 10 фраз из списка в Фазе 7.

---

## 📋 Фаза 2 — Prompt caching провайдера

**Зачем:** `SYSTEM_PROMPT` (~120 строк, ~800 токенов) одинаков для всех запросов — за него можно платить в 2–10 раз меньше при кэшировании на стороне провайдера.

**Файлы:**
- `backend/app/api/v1/ai.py` (функции `_call_ai_text`, `_call_ai_audio`)
- `backend/app/core/config.py` (флаг `AI_ENABLE_PROMPT_CACHE: bool = True`)

**Задачи:**
1. Уточнить у aitunnel.ru или в документации Gemini-прокси, поддерживается ли prompt caching и каким параметром включается (обычно это `cache_control: {"type": "ephemeral"}` в контенте system-сообщения либо автоматически при повторном одинаковом system-промте).
2. Если прокси не поддерживает — оставить флаг выключенным, задокументировать в плане и пропустить фазу.
3. Если поддерживает — обернуть system-сообщение соответствующим параметром.
4. Замерить эффект на тех же 10 фразах: `prompt_tokens` должен остаться прежним, но цена на стороне провайдера — упасть. Провайдер обычно возвращает `cached_tokens` в usage — залогировать его.

**Acceptance criteria:**
- Если поддержка есть: в логах видно `cached_tokens > 0` со второго запроса подряд.
- Если нет: `AI_ENABLE_PROMPT_CACHE=False` в `.env`, описать причину в коде комментарием.

**Риски:**
- Некоторые прокси игнорируют параметр → нужен именно замер, а не вера документации.

---

## 📋 Фаза 3 — Условные секции промта (section gating)

**Зачем:** для чисто расходной фразы «купил хлеб 100» секции долгов (30+ строк) бесполезны. Для «дал Васе 5000» бесполезны секции категорий/mappings.

**Файлы:**
- `backend/app/core/system_prompt.py` — разбить `SYSTEM_PROMPT` на модули, собирать динамически.
- `backend/app/core/text_heuristics.py` — **новый файл** с эвристиками.
- `backend/app/core/config.py` (флаг `AI_ENABLE_SECTION_GATING: bool = True`)

**Задачи:**

### 3.1. Разбить `SYSTEM_PROMPT` на модули

В `system_prompt.py` завести константы:
- `SP_HEADER` — первые 2 строки (вступление про JSON).
- `SP_TYPES_ALL` — секция 1 «Transaction Types» с ВСЕМИ типами.
- `SP_TYPES_NON_DEBT` — укороченная версия секции 1 только с `income`/`expense`.
- `SP_TYPES_DEBT_ONLY` — только `debt_*`.
- `SP_FIELDS` — секция 2 (required/optional).
- `SP_AUDIO` — секция 3.
- `SP_CATEGORIES` — секция 4.
- `SP_PREFERENCES` — секция 5.
- `SP_ITEM_PHRASE` — секция 6.
- `SP_COUNTERPARTS` — секция 7.
- `SP_DEBTS` — секция 8.
- `SP_LOCALE` — секция 9.
- `SP_SCHEMA_NON_DEBT` — JSON-пример без debt.
- `SP_SCHEMA_DEBT_NEW` — пример debt_give/take.
- `SP_SCHEMA_DEBT_PAYMENT` — пример debt_payment.

**Не трогать** текст секций — только разбить копипастой. Один осмысленный коммит.

### 3.2. Эвристика классификации (локальная, без LLM)

Создать `app/core/text_heuristics.py`:

```python
import re

DEBT_TRIGGERS_RU = [
    r"\bдал[аи]?\b", r"\bдаю\b", r"\bвзял[аи]?\b", r"\bбер[уё]т?\b",
    r"\bвернул[аи]?\b", r"\bотдал[аи]?\b", r"\bотдаю\b", r"\bзакрыл[аи]?\b",
    r"\bпогасил[аи]?\b", r"\bодолжил[аи]?\b", r"\bзанял[аи]?\b",
    r"\bдолг[а-я]*\b", r"\bв\s+долг\b", r"\bссудил[аи]?\b",
    r"\bрассчитал[аи]?ся\b", r"\bкинул[аи]?\b",
]
DEBT_TRIGGERS_EN = [
    r"\blent\b", r"\bborrow\w*\b", r"\bowe\w*\b", r"\bdebt\b",
    r"\brepaid?\b", r"\bpaid back\b", r"\bgave\b.+\$",
]

def looks_like_debt(text: str) -> bool:
    t = text.lower()
    return any(re.search(p, t) for p in DEBT_TRIGGERS_RU + DEBT_TRIGGERS_EN)

def has_proper_noun(text: str) -> bool:
    """Грубо: есть слово с заглавной в середине/начале, не в начале предложения."""
    # Берём слова длиннее 2 символов, начинающиеся с заглавной
    words = re.findall(r"\b[А-ЯA-Z][а-яa-zё]{2,}\b", text)
    # Отсекаем первое слово предложения (может быть просто началом фразы)
    if len(words) == 0:
        return False
    if len(words) == 1 and text.lstrip().startswith(words[0]):
        return False
    return True
```

**Стратегия классификации:**
- `looks_like_debt(text) == True` → собираем **debt-промт**: `SP_HEADER + SP_TYPES_ALL + SP_FIELDS + SP_AUDIO + SP_COUNTERPARTS + SP_DEBTS + SP_LOCALE + SP_SCHEMA_DEBT_NEW + SP_SCHEMA_DEBT_PAYMENT`.
- Иначе → **expense/income-промт**: `SP_HEADER + SP_TYPES_NON_DEBT + SP_FIELDS + SP_AUDIO + SP_CATEGORIES + SP_PREFERENCES + SP_ITEM_PHRASE + SP_LOCALE + SP_SCHEMA_NON_DEBT`.

**Важно:** в debt-промте всё равно упомянуть «если по ошибке это не долг — верни type=expense», чтобы эвристика-ложняк не ломала парсинг.

### 3.3. Новая функция `build_system_prompt(route: str) -> str`

В `system_prompt.py`:
```python
def build_system_prompt(route: str) -> str:
    if route == "debt":
        return "\n\n".join([SP_HEADER, SP_TYPES_ALL, SP_FIELDS, ...])
    return "\n\n".join([SP_HEADER, SP_TYPES_NON_DEBT, SP_FIELDS, ...])
```

Оставить старый `SYSTEM_PROMPT` как `SYSTEM_PROMPT_FULL` — fallback, если флаг выключен.

### 3.4. Интеграция в `ai.py`

В `parse_text`:
```python
from app.core.text_heuristics import looks_like_debt
route = "debt" if looks_like_debt(body.text) else "txn"
system_prompt = build_system_prompt(route) if settings.AI_ENABLE_SECTION_GATING else SYSTEM_PROMPT_FULL
```

Передавать `system_prompt` в `_call_ai_text` параметром (сейчас он берёт глобальный импорт).

**Acceptance criteria:**
- На «купил хлеб 100»: prompt_tokens снижается на ≥25%.
- На «дал Васе 5000»: prompt_tokens снижается на ≥15%.
- Все тесты из Фазы 7 проходят: ни один кейс не ломается при включённом флаге.

---

## 📋 Фаза 4 — Gating контрагентов

**Зачем:** список контрагентов (`body.counterparts`) не нужен, если в тексте нет имени собственного и нет долговых триггеров.

**Файлы:**
- `backend/app/core/system_prompt.py` — в `build_ai_prompt` передавать уже отфильтрованные списки.
- `backend/app/api/v1/ai.py` — считать `route` и `has_proper_noun` до вызова `build_ai_prompt`.

**Задачи:**
1. В `parse_text`:
   ```python
   use_counterparts = route == "debt" or has_proper_noun(body.text)
   counterparts_for_prompt = body.counterparts if use_counterparts else []
   ```
2. Передавать `counterparts_for_prompt` в `build_ai_prompt`.
3. Логировать флаг: `counterparts_sent={len(counterparts_for_prompt)}/{len(body.counterparts)}`.

**Acceptance criteria:**
- Тест «купил хлеб 100» с юзером, у которого 20 контрагентов → `counterparts_sent=0/20`.
- Тест «дал Васе 5000» → все контрагенты отправлены.
- Тест «купил у Ашана молоко» (есть proper noun, но не долг) → контрагенты отправлены (страховка).

---

## 📋 Фаза 5 — Hard-hit через mappings (детерминированный обход LLM для категории)

**Зачем:** если текст уже содержит известный `item_phrase` из `category_mappings`, категория определяется без LLM-раздумий. Промт сокращается, точность растёт.

**⚠️ Важно:** это **не замена** LLM — модель всё равно парсит сумму, дату, тип, лемматизирует item_phrase. Но категорию ей **подсказываем жёстко**.

**Файлы:**
- `backend/app/core/category_matcher.py` — **новый** модуль.
- `backend/app/api/v1/ai.py` — использование.

**Задачи:**

### 5.1. Лемматизация

Добавить зависимость `pymorphy3` (для русского). Для английского использовать просто `lower()` + базовый стемминг (или ничего — пока MVP).

```python
# backend/requirements.txt
pymorphy3==2.0.2
```

### 5.2. Матчер

```python
# backend/app/core/category_matcher.py
from functools import lru_cache
import pymorphy3

_morph = pymorphy3.MorphAnalyzer()

@lru_cache(maxsize=10000)
def lemmatize_ru(word: str) -> str:
    return _morph.parse(word)[0].normal_form

def lemmatize_text(text: str) -> set[str]:
    import re
    words = re.findall(r"[а-яёa-z]+", text.lower())
    return {lemmatize_ru(w) for w in words if len(w) >= 3}

def match_mapping(text: str, mappings: list[dict]) -> dict | None:
    """Возвращает маппинг-хит {item_phrase, category_name, weight} или None.
    Матчим, если хотя бы одно слово из item_phrase (лемма) есть в тексте (лемма).
    При нескольких совпадениях — берём с максимальным weight.
    """
    if not mappings:
        return None
    text_lemmas = lemmatize_text(text)
    best = None
    for m in mappings:
        phrase_lemmas = lemmatize_text(m["item_phrase"])
        if phrase_lemmas and phrase_lemmas.issubset(text_lemmas):
            if best is None or m["weight"] > best["weight"]:
                best = m
    return best
```

### 5.3. Использование в `parse_text`

```python
hit = match_mapping(body.text, mappings) if settings.AI_ENABLE_MAPPING_HARDHIT else None
if hit:
    # Добавляем инструкцию к user_prompt
    hint = f"\n## Category Hint (USE THIS CATEGORY)\nThe user already classified \"{hit['item_phrase']}\" as \"{hit['category_name']}\". Use this category in the response."
    user_prompt += hint
    logger.info(f"   🎯 Hard-hit: '{hit['item_phrase']}' → '{hit['category_name']}'")
```

**Без LLM мы всё равно не проставляем категорию**, потому что нужна лемматизация `item_phrase`, определение суммы и т.д. Но LLM получает жёсткий hint и не тратит токены на поиск по списку.

### 5.4. Конфиг

```python
# backend/app/core/config.py
AI_ENABLE_MAPPING_HARDHIT: bool = True
AI_MAPPING_MIN_WEIGHT: int = 1  # игнорировать маппинги слабее
```

**Acceptance criteria:**
- Юзер ранее сохранил маппинг «хлеб» → «Продукты».
- Текст «купил хлеб за 100» → в логе `🎯 Hard-hit: 'хлеб' → 'Продукты'`.
- Ответ LLM содержит `category_name="Продукты"`.
- Текст без матча → поведение не меняется.

---

## 📋 Фаза 6 — Семантический retry

**Зачем:** текущий retry тупо повторяет тот же промт при битом JSON. Улучшим: после первого ответа валидируем его, и при провале делаем второй вызов с **дельта-промтом**.

**Файлы:**
- `backend/app/api/v1/ai.py` — переработать `_call_ai_text`.
- `backend/app/core/response_validator.py` — **новый** модуль.

**Задачи:**

### 6.1. Валидатор

```python
# backend/app/core/response_validator.py
from typing import Literal

VALID_TYPES = {"income", "expense", "debt_give", "debt_take", "debt_payment"}
VALID_STATUSES = {"ok", "incomplete", "rejected"}

def validate_ai_response(
    data: dict,
    known_category_ids: set[str],
    known_counterpart_ids: set[str],
) -> tuple[bool, str | None]:
    """Возвращает (is_valid, error_message)."""
    st = data.get("status")
    if st not in VALID_STATUSES:
        return False, f"status must be one of {VALID_STATUSES}"
    if st == "rejected":
        return True, None
    if st == "ok":
        t = data.get("type")
        if t not in VALID_TYPES:
            return False, f"type must be one of {VALID_TYPES}"
        if not isinstance(data.get("amount"), (int, float)):
            return False, "amount must be a number"
        if t in ("debt_give", "debt_take", "debt_payment"):
            if not data.get("counterpart_name") and not data.get("counterpart_id"):
                return False, f"{t} requires counterpart_name or counterpart_id"
        if t == "debt_payment" and data.get("payment_flow") not in ("inbound", "outbound"):
            return False, "debt_payment requires payment_flow=inbound|outbound"
        cid = data.get("category_id")
        if cid and cid not in known_category_ids and not data.get("category_is_new"):
            return False, f"category_id {cid} not in user categories"
    return True, None
```

### 6.2. Стратегия retry

В `_call_ai_text`:
1. Первая попытка: как сейчас, `temperature=0.1`.
2. Если JSON битый → попытка 2 с `temperature=0.3` и добавлением в user-prompt: `"Your previous response was invalid JSON. Return ONLY valid JSON."`
3. Если JSON ок, но валидатор ругается → попытка 2 с сообщением: `"Your previous response had a problem: {error}. Fix ONLY this field and return the full corrected JSON."` (использовать messages с role=assistant с прошлым ответом, role=user с фидбэком).
4. Максимум 2 попытки. После — `HTTPException 502`.

### 6.3. Конфиг

```python
AI_ENABLE_SEMANTIC_RETRY: bool = True
AI_MAX_RETRIES: int = 2
```

**Acceptance criteria:**
- Тест-заглушка, где первый ответ LLM невалиден — второй вызов происходит с дельта-промтом (проверить по логам / моку).
- В норме `retries=0` — дополнительных вызовов нет.

---

## 📋 Фаза 7 — Тесты

**Файлы:**
- `backend/tests/test_ai_heuristics.py` — юниты на эвристики.
- `backend/tests/test_ai_prompt_build.py` — сборка промта под разные route.
- `backend/tests/test_ai_matcher.py` — матчер маппингов.
- `backend/tests/test_ai_parse_integration.py` — интеграция с мок-клиентом.
- `backend/scripts/ai_benchmark.py` — benchmark на реальных фразах.

**Набор фраз для бенчмарка (минимум 20, записать в `tests/fixtures/phrases.json`):**

Расходы:
- «купил хлеб за 100»
- «потратил 3000 на бензин»
- «оплатил подписку Netflix 999»
- «кафе 1500»
- «такси 450р»
- «купил вискаря за 2000»

Доходы:
- «получил зарплату 80000»
- «вернули 500 за возврат товара»
- «продал старый велик 15000»

Новые долги:
- «дал Васе 5000»
- «занял у мамы 3000 до пятницы»
- «одолжил Сергею 10000 на месяц»

Возвраты:
- «Вася вернул 2000»
- «отдал маме 1000»
- «закрыл долг перед банком» (incomplete — нет суммы)

Пограничные:
- «купил у Ашана молоко 80» (proper noun, но не долг)
- «пошёл гулять» (rejected — не финансы)
- «сегодня 200» (incomplete — нет типа)

**Acceptance criteria:**
- Все 20 фраз дают тот же финальный JSON с включёнными флагами оптимизации, что и без них (или лучше).
- Средние prompt_tokens снижены минимум на 30% относительно baseline.
- Среднее время ответа не выросло.

---

## 📋 Фаза 8 — (Опционально) Embeddings для категорий

**Когда включать:** если у живых юзеров в проде >50 категорий и Фазы 3–5 не дают достаточной экономии.

**Почему отложено:** требует новой зависимости, миграции БД, хранения векторов. Не делать преждевременно.

**Эскиз:**
- Модель: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (локально, CPU ≤100ms).
- Хранить embedding категории в поле `Category.embedding` (bytes/JSON).
- При парсинге: эмбеддинг текста → top-10 категорий по косинусу → в промт только их.
- Страховка: всегда включать последние 3 использованные и все parent-категории.

Детальный план писать только когда до этой фазы реально дойдёт.

---

## 🚦 Порядок катки

| Фаза | Приоритет | Ожидаемая экономия | Риск |
|------|-----------|---------------------|------|
| 1. Инструментация | P0 | 0% (но без неё слепы) | нулевой |
| 2. Prompt caching | P0 | 30–60% стоимости | низкий |
| 3. Section gating | P1 | 25–40% токенов | средний (эвристика может ошибаться) |
| 4. Counterparts gating | P1 | 10–20% токенов у части юзеров | низкий |
| 5. Mapping hard-hit | P2 | вариативно, растёт со временем | низкий |
| 6. Semantic retry | P2 | устойчивость, не токены | низкий |
| 7. Тесты | P0 | качество | нулевой |
| 8. Embeddings | P3 | условно | высокий |

Катить по одной фазе, каждую мерять бенчмарком из Фазы 1.

---

## 🧪 Откат

Каждая фаза — один фичефлаг в `.env`. Если что-то сломалось в проде:
```
AI_ENABLE_SECTION_GATING=false
AI_ENABLE_MAPPING_HARDHIT=false
AI_ENABLE_SEMANTIC_RETRY=false
AI_ENABLE_PROMPT_CACHE=false
```
Перезапуск бэкенда → поведение как до оптимизации.

---

## 🤖 Рекомендация по модели-исполнителю

Из представленного списка **для исполнения этого плана рекомендую**:

### Основной кандидат: **GPT-5.3-Codex Medium**
- Заточен под написание и рефакторинг кода по чёткой спецификации.
- «Medium» reasoning — достаточно для задач такого уровня детализации (нет ресёрча, только аккуратные правки).
- Хорошо работает с Python/FastAPI и Pydantic.
- Дешевле Opus, быстрее Thinking-моделей.

### Резерв: **Claude Sonnet 4.6 Thinking**
- Использовать, если Codex начнёт галлюцинировать названия функций/импортов или ломать стиль.
- Sonnet Thinking — более аккуратный с большими файлами, лучше держит контракт API.
- Дороже и медленнее Codex, но надёжнее в многошаговых рефакторингах (например, разбиение `SYSTEM_PROMPT` на модули — Фаза 3.1).

### Не рекомендую:
- **Claude Opus 4.6/4.7** — избыточно для этих задач, дорого.
- **GPT-5.4 Low Thinking** — слабее Codex на кодовых задачах.
- **Kimi K2.6** — «New», непроверен в проде MonPapa.
- **GLM-5.1** — избыточен по размеру для аккуратных правок.

### Как отдавать задачи исполнителю

Каждая фаза — отдельный промт. В промт включать:
1. Ссылку на этот файл (`Monpapa/todo/ai-prompt-optimization-plan.md`).
2. Конкретный раздел («Фаза 3.2»).
3. Acceptance criteria из плана.
4. Список файлов, которые можно трогать.
5. Требование: после реализации прогнать `backend/scripts/ai_benchmark.py` и приложить цифры до/после.

**Не отдавать весь план одним промтом** — даже сильная модель начнёт срезать углы на масштабе.
