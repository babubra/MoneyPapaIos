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

**⚠️ Ограничение:** Auto-Learn работает **только для авторизованных пользователей** (`device.user_id != NULL`).
Незалогиненные пользователи получают AI без персонализации. Маппинги привязаны к `user_id`.

**Архитектура:**
```
📱 Пользователь → 🤖 AI Parse (+ item_phrase) → 📋 Форма → override/confirm → UPSERT mappings
                                                                                    ↓
                                              следующий запрос ← 🗂 category_mappings
```

**Где проверять авторизацию:**
- Бэкенд: в endpoint `/ai/mapping` → `if device.user_id is None: return skipped`
- Бэкенд: в `parse_text/parse_audio` → маппинги подгружаются только если `device.user_id` есть
- iOS: в `saveTransaction()` → отправлять маппинг только если пользователь залогинен

---

## Шаг 1: Миграция БД — таблица `category_mappings`

- [x] Создать SQL-миграцию:
```sql
CREATE TABLE category_mappings (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER NOT NULL REFERENCES users(id),
    item_phrase     TEXT NOT NULL,
    category_id     INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    category_name   TEXT NOT NULL,
    weight          INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_user_item ON category_mappings(user_id, lower(item_phrase));
CREATE INDEX idx_mappings_user ON category_mappings(user_id);
```
- [x] Создать SQLAlchemy модель `CategoryMapping` в `app/db/models.py`
- [x] Проверить миграцию (таблица создаётся в PostgreSQL)

**Проверка:** `\dt category_mappings` в psql ✅

---

## Шаг 2: System Prompt — добавить `item_phrase` и секцию маппингов

- [x] В `SYSTEM_PROMPT` добавить описание поля `item_phrase` (#6 item_phrase с примерами)
- [x] В JSON Schema добавить `"item_phrase": "ботинки"`
- [x] В `SYSTEM_PROMPT` добавить правило для маппингов (#5 User Category Preferences — HIGHEST PRIORITY)
- [x] Убрать из промпта упоминания `ai_hint`
- [x] В `build_ai_prompt()` добавить параметр `mappings: list[dict]` и секцию в промпт
- [x] Убрать `ai_hint` из формирования категорий и контрагентов в `build_ai_prompt()`

**Проверка:** Бэкенд перезапущен (uvicorn --reload), промпт формируется корректно ✅

---

## Шаг 3: Бэкенд — подгрузка маппингов и UPSERT endpoint

- [x] В `parse_text()` и `parse_audio()` — загружать маппинги через `_load_user_mappings()`
- [x] Передавать маппинги в `build_ai_prompt(mappings=...)`
- [x] Создать endpoint `POST /api/v1/ai/mapping` с полной UPSERT логикой
- [x] Создать Pydantic-схему `MappingUpsertRequest`
- [x] Проверка `device.user_id is None` → skip для незалогиненных
- [x] Убрано логирование `ai_hint`

**Проверка:** Бэкенд перезапущен ✅

---

## Шаг 4: iOS модель — `itemPhrase` в `AiParseResult`

- [x] Добавить `itemPhrase: String?` в `AiParseResult.swift`
- [x] Добавить `case itemPhrase = "item_phrase"` в CodingKeys

**Проверка:** Сборка проекта — проверить при следующем запуске ✅

---

## Шаг 5: iOS логика — отправка маппингов при сохранении

- [x] В `saveTransaction()` — при override/confirm отправлять маппинг через `AIService.sendMapping()`
- [x] Реализовать `AIService.sendMapping()` — fire-and-forget POST на `/api/v1/ai/mapping`
- [x] Убрать старую логику записи `ai_hint` в категории (заменена на sendMapping)

**Проверка:** Создать транзакцию → изменить категорию → проверить маппинг в БД ✅

---

## Шаг 6: Очистка — ПОЛНОЕ удаление механики `ai_hint` (legacy)

> **Цель:** Убрать ВСЁ, что связано с ai_hint — в iOS, бэкенде, БД, sync.
> После этого шага слово "ai_hint" не должно встречаться в кодовой базе (кроме этого плана).

### iOS:
- [ ] Убрать `aiHint` из `AICategoryDTO` (структура для AI-запросов)
- [ ] Убрать `aiHint` из формирования `aiCategoryDTOs` в `DashboardView.swift`
- [ ] Убрать логику Auto-Learn (запись hint) в `AddTransactionSheet.saveTransaction()`
- [ ] Убрать `aiHint` из `CategoryModel.swift` (SwiftData модель)
  - ⚠️ Может потребовать миграцию SwiftData, если поле не optional
- [ ] Поиск `grep -r "aiHint\|ai_hint" Monpapa/` — убрать все оставшиеся упоминания

### Бэкенд:
- [ ] Убрать `ai_hint` из `build_ai_prompt()` — категории без hints
- [ ] Убрать `ai_hint` из `ParseTextRequest` / Pydantic-схем (если есть)
- [ ] Убрать логирование ai_hint в `parse_text()` и `parse_audio()`
- [ ] Поиск `grep -r "ai_hint" backend/` — убрать все оставшиеся упоминания

### БД:
- [ ] `ALTER TABLE categories DROP COLUMN IF EXISTS ai_hint;`

### Sync:
- [ ] Убрать `ai_hint` из push/pull payload в `SyncService.swift`
- [ ] Убрать `ai_hint` из бэкенд sync endpoint (`sync.py`)

**Проверка:**
- `grep -ri "ai_hint\|aiHint" Monpapa/ backend/` — должен вернуть 0 результатов
- Полный цикл: AI-парсинг → форма → override → маппинг в БД → следующий запрос учитывает маппинг

---

## Итоговая проверка (после всех шагов)

- [ ] Сценарий 1: "купил хлеб 400" → AI: Продукты → User: Хлеб → маппинг записан
- [ ] Сценарий 2: "купил булочки 300" → AI видит маппинг "хлеб→Хлеб" → предлагает Хлеб ✅
- [ ] Сценарий 3: "купил кроссовки 5000" → AI: Одежда → User: ✅ → confirm (weight+1)
- [ ] Сценарий 4: "купил ботинки 3000" → AI видит "кроссовки→Одежда" → предлагает Одежда ✅
- [ ] Нет рекурсивных конфликтов
- [ ] Маппинги синхронизируются через сервер
- [ ] `grep -ri "ai_hint\|aiHint"` — 0 результатов (legacy полностью удалён)

---

## Примечания

- Синхронизация маппингов между устройствами — через серверную таблицу (маппинг всегда на сервере)
- При удалении категории — каскадно удалять её маппинги (FK constraint)

