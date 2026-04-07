# AI Auto-Learn v1 — План реализации

> **⚠️ ПРАВИЛА РАБОТЫ С ЭТИМ ПЛАНОМ:**
> 1. Выполнять задачи **маленькими порциями** — по одному шагу за раз
> 2. **Согласовывать** начало каждого следующего шага с пользователем
> 3. После выполнения каждого пункта — **отметить** его как выполненный `[x]`
> 4. Не переходить к следующему шагу без подтверждения пользователя
> 5. После каждого шага — **проверять** работоспособность (сборка, тесты, ручная проверка)

---

## Контекст

**Проблема:** Текущая система `ai_hint` в категориях создаёт рекурсивные конфликты —
категории ссылаются друг на друга через hints, AI путается.

**Решение:** Агрегированная таблица `category_mappings` (item_phrase → category + weight).
AI сам выделяет `item_phrase` из текста транзакции. Вся таблица маппингов передаётся в промпт.

**Архитектура:**
```
📱 Пользователь → 🤖 AI Parse (+ item_phrase) → 📋 Форма → override/confirm → UPSERT mappings
                                                                                    ↓
                                              следующий запрос ← 🗂 category_mappings
```

---

## Шаг 1: Миграция БД — таблица `category_mappings`

- [ ] Создать SQL-миграцию:
```sql
CREATE TABLE category_mappings (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER NOT NULL REFERENCES users(id),
    item_phrase     TEXT NOT NULL,
    category_id     INTEGER NOT NULL REFERENCES categories(id),
    category_name   TEXT NOT NULL,
    weight          INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_item UNIQUE (user_id, lower(item_phrase))
);
CREATE INDEX idx_mappings_user ON category_mappings(user_id);
```
- [ ] Создать SQLAlchemy модель `CategoryMapping` в `app/db/models.py`
- [ ] Проверить миграцию (таблица создаётся в PostgreSQL)

**Проверка:** `\dt category_mappings` в psql

---

## Шаг 2: System Prompt — добавить `item_phrase` и секцию маппингов

- [ ] В `SYSTEM_PROMPT` добавить описание поля `item_phrase`:
  ```
  - item_phrase: the specific item/service. Extract core noun phrase.
    "купил хлеб за 400" → "хлеб"
    "потратил 3000 на бензин" → "бензин"
    "купил всякой мелочевки для дома" → "мелочевка для дома"
  ```
- [ ] В JSON Schema добавить `"item_phrase": "хлеб"`
- [ ] В `SYSTEM_PROMPT` добавить правило для маппингов:
  ```
  # User Category Preferences
  If item matches a preference below, use that category.
  Higher confidence = stronger signal.
  ```
- [ ] Убрать из промпта упоминания `ai_hint`
- [ ] В `build_ai_prompt()` добавить параметр `mappings: list[dict]` и секцию в промпт
- [ ] Проверить что промпт формируется корректно (логи бэкенда)

**Проверка:** Запустить бэкенд, отправить тестовый запрос, посмотреть лог промпта

---

## Шаг 3: Бэкенд — подгрузка маппингов и UPSERT endpoint

- [ ] В `parse_text()` и `parse_audio()` — загружать маппинги из БД:
  ```python
  mappings = await db.execute(
      select(CategoryMapping)
      .where(CategoryMapping.user_id == device.user_id)
  )
  ```
- [ ] Передавать маппинги в `build_ai_prompt()`
- [ ] Создать endpoint `POST /api/v1/ai/mapping` для UPSERT:
  ```python
  @router.post("/mapping")
  async def upsert_mapping(body: MappingRequest, device=Depends(require_device)):
      # UPSERT логика:
      # - если маппинг не существует → INSERT (weight=1)
      # - если существует, та же категория → weight += 1
      # - если существует, другая категория → UPDATE category, weight = 1
  ```
- [ ] Создать Pydantic-схему `MappingRequest`

**Проверка:** curl к endpoint, проверить запись в БД

---

## Шаг 4: iOS модель — `itemPhrase` в `AiParseResult`

- [ ] Добавить `itemPhrase: String?` в `AiParseResult.swift`:
  ```swift
  let itemPhrase: String?
  // CodingKeys:
  case itemPhrase = "item_phrase"
  ```
- [ ] Проверить что декодирование работает (JSON с item_phrase парсится)

**Проверка:** Сборка проекта без ошибок

---

## Шаг 5: iOS логика — отправка маппингов при сохранении

- [ ] В `saveTransaction()` — при override/confirm отправлять маппинг на сервер:
  ```swift
  if let itemPhrase = prefill?.itemPhrase,
     let category = categoryToSave {
      Task {
          await AIService.shared.sendMapping(
              itemPhrase: itemPhrase,
              categoryId: category.clientId,
              categoryName: category.name,
              isOverride: chosen.name != aiSuggested
          )
      }
  }
  ```
- [ ] Реализовать `AIService.sendMapping()` — POST на `/api/v1/ai/mapping`
- [ ] Убрать старую логику записи `ai_hint` в категории

**Проверка:** Создать транзакцию, изменить категорию, проверить маппинг в БД

---

## Шаг 6: Очистка — убрать `ai_hint`

- [ ] Убрать `aiHint` из `AICategoryDTO` (не передаётся в AI)
- [ ] Убрать формирование `aiHint` из `DashboardView.aiCategoryDTOs`
- [ ] Оставить поле `aiHint` в `CategoryModel` (не ломать миграцию SwiftData)
- [ ] Убрать `ai_hint` из `build_ai_prompt()` (категории без hints)

**Проверка:** Полный цикл: AI-парсинг → форма → override → маппинг в БД → следующий запрос учитывает маппинг

---

## Итоговая проверка (после всех шагов)

- [ ] Сценарий 1: "купил хлеб 400" → AI: Продукты → User: Хлеб → маппинг записан
- [ ] Сценарий 2: "купил булочки 300" → AI видит маппинг "хлеб→Хлеб" → предлагает Хлеб ✅
- [ ] Сценарий 3: "купил кроссовки 5000" → AI: Одежда → User: ✅ → confirm (weight+1)
- [ ] Сценарий 4: "купил ботинки 3000" → AI видит "кроссовки→Одежда" → предлагает Одежда ✅
- [ ] Нет рекурсивных конфликтов
- [ ] Маппинги синхронизируются через сервер

---

## Примечания

- `ai_hint` в CategoryModel оставляем до следующей миграции SwiftData (во избежание потери данных)
- Синхронизация маппингов между устройствами — через серверную таблицу (маппинг всегда на сервере)
- При удалении категории — каскадно удалять её маппинги (FK constraint)
