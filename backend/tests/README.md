# `backend/tests/` — pytest-инфраструктура

> **Эта папка — постоянная, не одноразовая.** Перед любой правкой
> `backend/app/api/v1/ai.py`, `backend/app/core/system_prompt.py`,
> сменой `AI_MODEL` или upgrade `openai`-SDK — сюда обращаемся в первую очередь.
>
> Когда: создано в сессии M14 (2026-05-11), см. [`todo/audit/C1_C2_ai_layer.md`](../../todo/audit/C1_C2_ai_layer.md) finding #14.

---

## TL;DR — три команды

```bash
cd backend && source venv/bin/activate

# 1. Быстрая проверка (без сети, без денег, ~0.5 сек)
pytest tests/ --ignore=tests/golden

# 2. Полная проверка с реальным aitunnel (~20 сек, ~$0.03)
pytest tests/

# 3. Только долги (если правишь SYSTEM_PROMPT раздел 7-8)
pytest tests/golden -v -k debt
```

Текущее состояние: **57 passed, 4 xfailed** в полном прогоне. xfailed — это маркеры известных багов, которые автоматически станут green после соответствующих фиксов (см. ниже).

---

## Установка (один раз)

```bash
cd backend && source venv/bin/activate
pip install -r requirements-dev.txt
```

Зависимости (`pytest`, `pytest-asyncio`) — отдельный файл от runtime `requirements.txt`, не утяжеляют production-образ. Из Docker-образа `tests/`, `pytest.ini`, `requirements-dev.txt` исключены через [`.dockerignore`](../.dockerignore).

---

## Структура

| Папка / файл | Назначение | Время | Сеть |
|---|---|---|---|
| `tests/conftest.py` | Фикстуры `mock_ai_client`, `make_response`, авто-загрузка `.env` | — | — |
| `tests/unit/` | Юнит-тесты чистых функций (`_sanitize_json`, `_normalize_null_strings`, `build_ai_prompt`) | <0.5s | нет |
| `tests/test_call_ai_text.py` | Мок-тесты `_call_ai_text` — retry, error handling, usage-логирование | <0.5s | нет |
| `tests/eval/` | Мок-эвалы regression нашего обработчика (когда AI вернёт X, наш код даст Y) | <0.5s | нет |
| `tests/golden/` | Реальные вызовы aitunnel — измеряют качество модели | ~20s | **да** |
| `tests/golden/README.md` | Стоимость, как добавить кейс, что делать при падении | — | — |

---

## Когда что прогонять

### Перед коммитом любых правок в `backend/app/api/v1/ai.py`

```bash
pytest tests/ --ignore=tests/golden
```

Достаточно — это ловит регрессии нашего Python-слоя (sanitize, retry, error handling). Сеть не нужна.

### Перед правкой `backend/app/core/system_prompt.py` (M13, C3)

**Baseline:**
```bash
pytest tests/golden -v 2>&1 | tee /tmp/golden-before.log
```

Запиши счёт: сколько passed, сколько xfailed, общее время, видимые `cached_tokens` в логе.

**После правки промпта:**
```bash
pytest tests/golden -v 2>&1 | tee /tmp/golden-after.log
```

Сравни. Ожидание: `passed` не уменьшается. xfailed могут стать passed (это значит баг закрыт правкой) — это XPASS, нормальное явление, маркер можно убрать из cases.py.

### При смене `AI_MODEL` в `.env`

Полный прогон `pytest tests/`. Падения golden — повод расследовать у провайдера, не торопиться выкатывать.

### При upgrade `openai` SDK или библиотек

`pytest tests/ --ignore=tests/golden` — структурные регрессии (API contract `_call_ai_text`) поймаются здесь. Если зелено — можно перейти к golden.

### Если просто хочется проверить долги после правки промпта

```bash
pytest tests/golden -v -k debt
```

8 кейсов, ~10 секунд, ~$0.02. Покрывают: `debt_take` (новый + диминутив), `debt_give`, `debt_payment` (outbound/inbound/morphology/ambiguous), english diminutive.

---

## Что значит каждое xfail сейчас (2026-05-11)

| Тест | Reason | Закроется через |
|---|---|---|
| `tests/unit/test_sanitize_json.py::test_preserves_url_in_string_value` | C2.19 — `_sanitize_json` режет `//` в URL | Правкой regex в `_sanitize_json` |
| `tests/unit/test_build_ai_prompt.py::test_unknown_locale_does_not_leak_raw_code` | C2.21 — неизвестная локаль попадает в промпт сырой | Pattern в `ParseTextRequest.locale` |
| `tests/eval/test_eval_text.py::test_mock_eval[m6_url_in_raw_text_through_sanitize]` | C2.19 (та же) | Закроется вместе с #19 |
| `tests/golden/test_golden_text.py::test_golden[ru_incomplete_amount]` | C3 — модель не выставляет `status=incomplete` при отсутствии amount | Усиление формулировки SYSTEM_PROMPT раздел 2 |

Когда правка приземлится — тест автоматически станет XPASS, потом убираем `xfail_reason` из cases.py.

---

## Как добавить новый кейс

### Mock-эвал (`tests/eval/cases.py`)

Когда нужно зафиксировать поведение **нашего обработчика** на конкретном AI-ответе (например, новая edge-case в sanitize, новая обработка null-полей). Формат описан в docstring `cases.py`.

```python
{
    "id": "m7_my_new_case",
    "text": "что юзер написал",
    "categories": [...],
    "counterparts": [...],
    "locale": "ru",
    "mock_response": {...},   # что вернёт «AI» (dict или строка)
    "expected_subset": {...}, # что должно остаться в результате
}
```

### Golden-кейс (`tests/golden/cases.py`)

Когда нужно измерить **качество модели** на новом сценарии. См. [`tests/golden/README.md`](golden/README.md) — там детально про принципы assertions (жёсткие/мягкие/`assert_present`) и как сгенерировать ground-truth через `backend/dump_prompt.py`.

---

## Что делать, если тест упал

1. **Прочитать ассерт в выводе pytest** — там полный `result` со всеми полями, не нужно гадать.
2. **Понять слой падения:**
   - Юнит/мок упал → регрессия нашего Python-кода. Скорее всего, мы только что что-то сломали.
   - Golden упал → либо ассерт слишком жёсткий, либо модель/aitunnel изменили поведение, либо SYSTEM_PROMPT недостаточно явный.
3. **Для golden — три типичных решения:**
   - Смягчить assert (`assert_equals` → `assert_in`)
   - Исправить SYSTEM_PROMPT, если правило в промпте слабое (это работа блока **C3** в [`todo/claude_code_opus_4.7_plan.md`](../../todo/claude_code_opus_4.7_plan.md))
   - Если модель/aitunnel реально сломались — зафиксировать дату и расследовать у провайдера
4. **Никогда не «делать тест зелёным» удалением проверки** — лучше xfail с понятным reason, чтобы причина была видна в выводе и не забылась.

---

## Sanity: проверить, что `tests/` не попадают в Docker-образ

После рефакторов `.dockerignore`:

```bash
cd backend
docker compose build
docker compose run --rm backend ls /app/   # tests/ не должен присутствовать
```

---

## Ссылки

- Полный план M14: [`~/.claude/plans/breezy-wandering-church.md`](../../.claude/plans/breezy-wandering-church.md)
- Аудит-отчёт C1+C2 (где живут findings #1–#21): [`todo/audit/C1_C2_ai_layer.md`](../../todo/audit/C1_C2_ai_layer.md)
- Глобальный план аудита: [`todo/claude_code_opus_4.7_plan.md`](../../todo/claude_code_opus_4.7_plan.md)
