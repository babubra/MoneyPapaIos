# Golden-сьюит — реальные вызовы aitunnel

## Что это

15 параметризованных кейсов, которые бьют в `gemini-2.5-flash-lite` через
aitunnel.ru и проверяют качество парсинга на боевом стенде. В отличие от
`tests/eval/` (там моки), golden измеряет **модель**, не наш Python-обработчик.

Все тесты помечены `@pytest.mark.golden`. По умолчанию запускаются вместе
с остальным `pytest tests/` — но автоматически skip'аются, если не задан
`AITUNNEL_API_KEY`.

## Запуск

```bash
cd backend

# 1. установить dev-зависимости (если ещё нет)
pip install -r requirements-dev.txt

# 2. убедиться, что ключ в окружении (либо в .env, либо export)
export AITUNNEL_API_KEY=...

# 3. прогнать golden
pytest tests/golden -v

# 4. конкретный сценарий
pytest tests/golden -v -k ru_debt_payment_diminutive
pytest tests/golden -v -k debt          # все 8 кейсов на долги

# 5. видеть usage tokens (baseline стоимости)
pytest tests/golden -v --log-cli-level=INFO -k ru_debt_payment_outbound
```

## Стоимость

Один полный прогон 15 кейсов ≈ $0.02–0.05 на gemini-2.5-flash-lite через aitunnel:
- input: ~3500 токенов (SYSTEM_PROMPT 4000 chars + user-prompt ~500 chars) × 15
- output: ~200 токенов × 15

Включаем `_log_ai_usage` (см. `backend/app/api/v1/ai.py:216`) — реальные числа
видны в pytest-выводе с `--log-cli-level=INFO`. Это baseline для будущих
сравнений с **M13** (сокращение SYSTEM_PROMPT) и **#1** (prompt caching).

## Что покрывает

| Группа | Кейсов | Главное |
|---|---|---|
| Базовые транзакции | 3 | income/expense ru+en |
| Категории / lemmatization | 2 | new category, item_phrase в Nominative |
| **Долги** | **8** | debt_take/debt_give/debt_payment, fuzzy-matching counterpart (Сергей/Серёжа/Сергей Иванов), payment_flow inbound/outbound, ambiguous-counterparts |
| Off-topic / incomplete | 2 | status=rejected/incomplete |

Главный фокус — долги: проверяем, что модель следует SYSTEM_PROMPT разделам 7–8
(fuzzy-matching counterpart, правильный `payment_flow`).

**Важно про ambiguous-кейс** (`ru_debt_payment_ambiguous`): когда в контексте
есть два «Сергея» (Иванов и Петров) и юзер пишет «отдал долг Сереже 1000»,
модель выберет **одного** из них — какого именно недетерминированно. Тест
проверяет только что counterpart **не создан как новый** (`counterpart_is_new=false`)
и что выбран один из существующих ID. Дальнейший выбор «к какому именно долгу
применить платёж» делает iOS-сторона: после получения `counterpart_id`
от AI клиент фильтрует все открытые долги этого контрагента и предлагает
юзеру выбрать.

## Принципы assertions

- **Жёсткие (`assert_equals`)** — там, где SYSTEM_PROMPT прямо предписывает:
  `type=debt_payment` для «вернул/отдал», `counterpart_is_new=false` при наличии
  fuzzy-match в списке, корректный `payment_flow`.
- **Мягкие (`assert_in`)** — там, где модель имеет право колебаться: `currency`
  при отсутствии явного знака, `counterpart_id` среди нескольких допустимых,
  `status` ∈ {rejected, incomplete} для off-topic.
- **Присутствие (`assert_present`)** — для полей, где значение зависит от модели:
  `category_name` у новой категории, `item_phrase`, `counterpart_name` у нового.

## Что делать, если кейс упал

1. Прочитать полный `result` из assert-message (вывод pytest).
2. Понять причину: модель деградировала, aitunnel изменил поведение,
   SYSTEM_PROMPT не покрывает edge-case, или ассерт слишком жёсткий.
3. Если ассерт слишком жёсткий — смягчить (`assert_equals` → `assert_in`).
4. Если модель не следует промпту — править `backend/app/core/system_prompt.py`
   (это работа блока **C3** в [`todo/claude_code_opus_4.7_plan.md`](../../../todo/claude_code_opus_4.7_plan.md)).
5. Если модель/aitunnel реально сломались — фиксировать дату и расследовать
   у провайдера.

## Как добавить кейс

Простой путь — взять реальный пользовательский запрос, прогнать через
[`backend/dump_prompt.py`](../../dump_prompt.py) (требует БД), убедиться что AI
отвечает корректно, и добавить запись в `cases.py`. Формат описан в docstring
файла `cases.py`.

Если кейс требует контекст (categories/counterparts) — лучше **придумать
синтетический** (как `u1`/`u2`/`u3` сейчас), не копировать реальный user_id'ы
из БД (это PII).
