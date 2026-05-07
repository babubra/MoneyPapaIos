# Production Readiness Audit — Global Plan

> Автор: Claude Code (Opus 4.7), сессия от 2026-05-04
> Цель: довести Monpapaios (backend + Monpapa frontend + AI-слой + infra) до production-ready состояния

---

## Контекст

> **2026-05-04 — изменение auth-модели.** Принято решение перейти со схемы «опциональный логин» на схему **C** (обязательная авторизация + AI trial + платная sync). Полный план миграции: [`auth_model_C_migration.md`](auth_model_C_migration.md). Аудит A1 после этого решения частично теряет силу (см. update в [`audit/A1_backend_surface.md`](audit/A1_backend_surface.md)), но большинство findings валидны при любой архитектуре.

> **2026-05-05 — pragmatic-миграция Auth Model C реализована** (коммиты `5384e08`..`673345f`). Закрыто 6 из 13 findings A1 (SECRET_KEY, `/auth/device`, `--reload`, CORS wildcard, dev-скрипты в образе, healthcheck), 2 ужесточены (DEV_MODE, PIN brute-force). Подробности в [`auth_model_C_migration.md`](auth_model_C_migration.md) → раздел «Связь с production-readiness аудитом». Apple Sign-In runtime + StoreKit 2 оставлены как заглушки (требуют Apple Developer Program).

> **2026-05-06 — A1-fixups выполнен.** Закрыты оставшиеся criticals/mediums: 🔴 IDOR через `category_id`/`counterpart_id`/`parent_id` (CRUD + sync), host-header injection в magic-link, PII в логах, `/docs` в проде, audio size + MIME whitelist, `forwarded_allow_ips`, `EmailStr`, mass-assignment whitelist. Verified curl-сценариями (см. секцию «Update 2026-05-06» в [`audit/A1_backend_surface.md`](audit/A1_backend_surface.md)). Отложено по дизайну: refresh-tokens (A2), Alembic (D1), secrets-management (D3).

Приложение работает, но не готово к проду. Известные проблемы:
- Открытые эндпоинты в бэкенде
- DeviceID-based rate-limiting на клиенте (легко обходится — можно накидать миллион случайных deviceID и слить AI-квоту)
- Нет чёткого разделения dev / prod режимов
- Возможна неэффективность во фронтенде (дублирование компонентов, лишние ререндеры, jank UI)
- Полный текст промпта отправляется в AI каждый раз — стоимость и задержка под вопросом

**Стек:**
- **Backend** (`backend/`): Python + FastAPI 0.115, SQLAlchemy 2.0 async + asyncpg, Alembic, Pydantic Settings, python-jose (JWT) + passlib/bcrypt, httpx, aiosmtplib
- **Frontend** (`Monpapa/`): iOS native, SwiftUI, Xcode-проект (`Monpapa.xcodeproj`), локализация через `Localizable.xcstrings`, design tokens. Сервисы: `AIService`, `AuthService`, `KeychainService`, `SyncService`, `StatsService`, `AudioRecorderService`, `LocalizationManager`, `MPLogger`, `APIConfig`
- **БД:** PostgreSQL 16 (Docker)
- **AI:** OpenAI SDK (`openai==1.75.0`), system prompt в `backend/app/core/system_prompt.py`
- **Деплой:** GitHub Actions + Docker Compose (`backend/docker-compose.yml`, hot-reload в dev через volume mount)

---

## Структура аудита

Каждый блок = отдельная сессия Claude Code. Выход — markdown-отчёт в `todo/audit/<block_id>.md`.
**Правило:** в сессиях аудита код НЕ правится, только отчёт. Правки — отдельные сессии по конкретным findings.

### A. Backend (security & API)

| ID | Тема | Что проверяем |
|----|------|---------------|
| A1 | Карта attack surface | Все эндпоинты, какие требуют auth, какие открыты, есть ли rate-limit, валидация входа, утечки секретов в коде/логах |
| A2 | Auth & rate-limiting | DeviceID-схема, JWT/session lifecycle, защита от спама deviceID, IP/fingerprint квоты, server-side counters |
| A3 | Data layer | SQL/NoSQL injection, ORM-запросы, миграции, индексы, утечки PII в ответах API |
| A4 | Dev/prod parity | env-vars, CORS, security headers, debug-режимы, логирование секретов, разница конфигов |

### B. Frontend (architecture & performance)

| ID | Тема | Что проверяем |
|----|------|---------------|
| B1 | Архитектура компонентов | Дублирование, переиспользование, размер компонентов, presentational/container, dead code |
| B2 | State management | Где хранится state, лишние ре-рендеры, prop drilling, утечки памяти, подписки |
| B3 | UI performance & smoothness | FPS, jank на скроллах/анимациях, размер бандла, lazy loading, изображения, ререндеры списков |
| B4 | UX consistency | Design tokens (есть в последнем коммите), отступы/типографика, состояния loading/error/empty, accessibility |

### C. AI слой (отдельно — main cost driver)

| ID | Тема | Что проверяем |
|----|------|---------------|
| C1 | Prompt engineering audit | Корректность отправки полного промпта, prompt caching, system vs user разделение, температура/модель под задачу |
| C2 | Cost & latency | Токен-бюджеты, кэширование ответов, выбор модели (Haiku vs Sonnet vs Opus под задачу), батчинг, streaming, **trial-abuse cap (см. ниже)** |
| C3 | Качество ответов | Детерминизм, валидация JSON-выхода, fallback при ошибках/таймаутах, evaluations |

#### Известные issues для C2 (зафиксировано до сессии аудита)

**1. Trial-bypass через смену аккаунта на одном устройстве** (2026-05-06)
- **Что:** `User.ai_trial_used` обнуляется при каждом новом аккаунте. На одном физическом телефоне можно создать N email-аккаунтов и получить `N × AI_TRIAL_LIMIT` запросов. Cost для атакующего ≈ 0 (любой почтовый домен-однодневка), cost для нас = реальные OpenAI-токены.
- **Почему сейчас выдержимо:** магнитуда 50 запросов ≈ $0.05–0.10 на gpt-4o-mini, мотивация атаковать слабая. Apple Sign-In (когда подключим) режет этот вектор естественно.
- **Что мы упустили:** в `Device` модели **уже есть** поля `ai_requests_today`, `ai_audio_requests_hour`, `is_blocked` (`backend/app/db/models.py:99-107`) — но **не инкрементируются и не проверяются нигде в коде**. Мёртвый код, оставшийся от прежней device-only схемы.
- **Что предлагается в C2:** активировать `Device.ai_requests_today` как мягкий per-device daily-cap (например, 30/день/устройство, считается **поверх всех user'ов** этого device_id). Это не заменит `User.ai_trial_used`, а наложится сверху: легитимный юзер не упрётся (~30/день в 10× больше типичного использования), а burst-атака «100 emails на одном телефоне = 5000 запросов» режется до 30. Бонус: `is_blocked = true` автоматически при аномалии (например, ≥6 разных user_id на device за сутки).
- **Tradeoffs, которые нужно проверить в C2:** (а) что делать с device при `DELETE /auth/account` — каскад `SET NULL` уже стоит, счётчик переживёт удаление user'а ✓; (б) как считать «суммарно по всем user'ам device» — простой счётчик на Device без привязки к user, сбрасываемый по дате; (в) UX: сообщение об упоре в device-cap должно отличаться от user-trial-cap, чтобы не путать юзера; (г) Premium-юзеров device-cap не касается (как и сейчас trial).

#### Известные issues для C3 (зафиксировано до сессии аудита)

**1. Конфликт SYSTEM_PROMPT разделов 4 и 5 — preferences перекрывают явный intent юзера в тексте** (2026-05-07)
- **Где:** [`backend/app/core/system_prompt.py:24-31`](../backend/app/core/system_prompt.py) (раздел 4 «Categories»: «if no existing category fits → create new with `category_is_new=true`»), [`backend/app/core/system_prompt.py:38-42`](../backend/app/core/system_prompt.py) (раздел 5 «User Category Preferences (HIGHEST PRIORITY)»: «**These OVERRIDE all other category logic.** If the current item matches a preference (even loosely/semantically), you MUST use that category»).
- **Что:** реальный кейс на user_id=19 (2026-05-07, 22:47): юзер ввёл «Запиши в категорию **молочные продукты** кефир за 500 рублей». Категории «Молочные продукты» в SwiftData нет, есть только родительская «Продукты». Маппинг `сметана → Продукты` (weight 1) был создан часом ранее. Модель (`gemini-2.5-flash-lite`) выбрала «Продукты» вместо создания новой «Молочные продукты», ссылаясь на семантическую близость кефир≈сметана через раздел 5. Скриншот в сессии есть; полный prompt с воспроизведением — `backend/prompt_user19_kefir.txt` (генерится через `backend/dump_prompt.py`).
- **Почему так происходит:** в промпте раздел 5 говорит «MUST OVERRIDE» сильнее, чем раздел 4. Явная инструкция юзера в тексте («запиши в категорию X», «отнеси к Y», «поставь Z») не описана в промпте отдельным правилом — для модели она = просто часть текста, а preferences = HIGHEST PRIORITY.
- **Артефакт исследования (для C3-сессии):**
  - [`backend/dump_prompt.py`](../backend/dump_prompt.py) — утилита, выгружает точный prompt (SYSTEM + categories + counterparts + mappings) для конкретного `user_id` и текста. Позволяет сравнивать ответы разных моделей на ОДНОМ prompt'е без запуска бэка. Поддерживает `--no-mappings` для проверки эффекта раздела 5.
  - Минимальный воспроизводящий пример (для eval-набора M14): user с категориями `[Продукты, Алкоголь]` + маппингом `сметана → Продукты`, текст «запиши в категорию молочные продукты кефир за 500». Ground truth: `category_is_new=true, category_name="Молочные продукты"`.
- **Что предлагается в C3:** (а) добавить в SYSTEM_PROMPT раздел 5b или правило в раздел 4 с приоритетом выше preferences: «If user explicitly states a category in the text (patterns: 'запиши в категорию X', 'отнеси к Y', 'поставь Z', 'category: X'), that explicit instruction OVERRIDES preferences and MUST be used as `category_name` with `category_is_new=true` if not in the existing list»; (б) добавить 2-3 примера в SYSTEM_PROMPT под этим правилом; (в) прогнать eval-набор (M14) до и после правки на ≥3 моделях (gemini-2.5-flash-lite + 1-2 кандидата из baseline); метрика — accuracy по `category_name`/`category_is_new` на сценариях с явным intent.
- **Tradeoffs, которые нужно проверить в C3:** (а) **regex или семантика?** Жёсткая строка-паттерн («запиши в категорию X») надёжна, но не покроет «положи в X», «это X», «как X»; семантическое распознавание полагается на LLM, на слабых моделях (Qwen 30B, GLM Air из [`baseline.md`](audit/C1_C2_baseline.md)) может не сработать. (б) **multi-locale.** Правило должно работать на 12 локалях из `_LOCALE_MAP` — нужны примеры на ru/en минимум, для остальных — formulation на английском «if user explicitly states» обычно генерализуется. (в) **conflict resolution с preferences.** Если у юзера есть `сметана → Продукты` и он пишет «купил кефир» (без явного intent) — должно остаться `Продукты` (preferences работают). Только при явной инструкции — override. (г) **false positives.** Текст «купил кефир в категорию `молоко`» вряд ли встретится, но «купил молочную продукцию для категории здоровья» может сбить — нужно проверить на edge-кейсах. (д) **token cost.** Дополнительное правило раздела 5b добавит ~150-300 input-токенов на каждый запрос — нужно учитывать в M13 (сокращение SYSTEM_PROMPT).

### D. Infra & deploy

| ID | Тема | Что проверяем |
|----|------|---------------|
| D1 | Deploy pipeline | Текущий GitHub Actions deploy, rollback, zero-downtime, health checks |
| D2 | Observability | Логи, метрики, алерты (особенно по AI cost), error tracking |
| D3 | Backup & secrets | БД бэкапы, ротация ключей, где хранятся secrets (env? vault?) |

### E. Future work (после всех аудит-блоков)

| ID | Тема | Что включает |
|----|------|--------------|
| E1 | AI usage telemetry & admin dashboard | Persistent storage AI usage (таблица `AiUsageDaily(user_id, date, prompt/completion/cached/total tokens, count_text, count_audio)`), `INSERT … ON CONFLICT (user_id, date) DO UPDATE … += EXCLUDED.*` после каждого AI-вызова, админ-эндпоинт `GET /api/v1/admin/ai-usage` (фильтры по дате/юзеру, top-N), доступ через `ALLOWED_ADMINS` (CSV email в `.env`) — без отдельного `is_admin` поля. Web-UI — отдельным следующим шагом (Jinja-страница в FastAPI или внешний фронт). Зависит от: M6 (baseline-лог, формат полей должен совпадать), `D1` (Alembic baseline) — желательно, чтобы добавление таблицы не требовало `docker compose down -v`. |

---

## Рекомендуемый порядок выполнения

По убыванию пользы за токен:

1. ✅ **A1** — backend attack surface (фундамент для всего security)
2. ✅ **A1-fixups** — IDOR + host-header + /docs + PII + audio limit + EmailStr + forwarded_allow_ips закрыты (2026-05-06)
3. **C1 + C2** — AI prompt & cost (горящие деньги) ← **следующая сессия**
4. **A2** — auth & rate-limit (на новой архитектуре после миграции C: brute-force `/verify-pin` под multi-IP, нет per-user daily-cap для Premium, refresh-token lifecycle)
5. **B1 + B2** — frontend архитектура (техдолг растёт быстрее тут)
6. **B3** — UI smoothness (после B1 часть jank уйдёт сама)
7. **A3, A4** — data, dev/prod (важно, но менее срочно)
8. **C3** — качество AI-ответов
9. **D1–D3** — infra (когда код готов к проду; включая VPS deploy + Alembic baseline)
10. **E1** — AI usage telemetry & admin dashboard (поверх baseline-логов M6, в самую последнюю очередь — когда D1 готов и остальное стабильно)

---

## Как использовать план в новой сессии

В новой сессии Claude Code (или другой модели) скажи:

> "Прочитай `todo/claude_code_opus_4.7_plan.md` и начни с блока **<ID>**. Отчёт положи в `todo/audit/<ID>_<short_name>.md`."

Пример:
> "Прочитай `todo/claude_code_opus_4.7_plan.md` и начни с блока **A1**. Отчёт положи в `todo/audit/A1_backend_surface.md`."

---

## Формат сессии аудита

**Вход:**
- ID блока из этого плана
- Ссылки на ключевые файлы (если уже известны; иначе модель находит сама через grep/Explore-агента)

**Выход:** один файл `todo/audit/<ID>_<name>.md` со структурой:
```markdown
# <ID>: <Название блока>
> Сессия: <дата>, модель: <model_id>

## Summary
<2–3 предложения: что нашли, главные риски>

## Findings

### 🔴 Critical
- **<Заголовок>** — `path/to/file.ts:42`
  - Что: <описание>
  - Риск: <impact>
  - Рекомендация: <fix>

### 🟡 Medium
...

### 🟢 Low / Nice-to-have
...

## Что не покрыли
<честный список того, что осталось за рамками сессии>
```

**Жёсткие правила:**
- Код НЕ правится, только отчёт
- Severity по шкале 🔴 Critical / 🟡 Medium / 🟢 Low
- Каждый finding должен ссылаться на `файл:строку`
- В конце — секция "Что не покрыли" (честность важнее полноты)

---

## Status tracker

| Блок | Статус | Сессия | Отчёт |
|------|--------|--------|-------|
| A1 | ✅ Done | 2026-05-04 (Opus 4.7) | [`audit/A1_backend_surface.md`](audit/A1_backend_surface.md) |
| **C-migration** | 🟢 Pragmatic done | 2026-05-05 (Opus 4.7) | [`auth_model_C_migration.md`](auth_model_C_migration.md) — коммиты `5384e08`..`673345f` |
| **A1-fixups** | ✅ Done | 2026-05-06 (Opus 4.7) | IDOR + mass-assignment + host-header + `/docs` + PII + audio + `forwarded_allow_ips` + `EmailStr` — см. секцию «Update 2026-05-06» в [`audit/A1_backend_surface.md`](audit/A1_backend_surface.md) |
| A2 | ⬜ TODO | — | — |
| A3 | ⬜ TODO | — | — |
| A4 | ⬜ TODO | — | — |
| B1 | ⬜ TODO | — | — |
| B2 | ⬜ TODO | — | — |
| B3 | ⬜ TODO | — | — |
| B4 | ⬜ TODO | — | — |
| C1 | ✅ Done | 2026-05-06 (Opus 4.7) | [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) (объединён с C2) |
| C2 | ✅ Done | 2026-05-06 (Opus 4.7) | [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) (объединён с C1) |
| **C1+C2-fixups** | 🔄 In progress | 2026-05-07 (Opus 4.7) | M6 + #4 + #5 + #7 закрыты — baseline + caps. Дальше: M14 (eval) → M13 (promptlen) → #3/#15. См. [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) |
| C3 | ⬜ TODO | — | — |
| D1 | ⬜ TODO | — | VPS deploy + Alembic baseline (когда вернётся VPS) |
| D2 | ⬜ TODO | — | — |
| D3 | ⬜ TODO | — | — |
| E1 | ⬜ TODO | — | AI usage telemetry + admin dashboard (поверх M6, требует Alembic — D1) |

> Обновляй эту таблицу после каждой сессии: ⬜ TODO → 🔄 In progress → ✅ Done

---

## История ревизий плана

- 2026-05-04 — план создан (Opus 4.7), сессия `inspiring-dewdney-4e595d`
- 2026-05-04 — добавлен баннер про Auth Model C (план миграции вышел отдельным файлом)
- 2026-05-04 — A1-аудит выполнен, отчёт `audit/A1_backend_surface.md`, статус → ✅ Done
- 2026-05-05 — pragmatic-реализация Auth Model C (коммиты `5384e08`..`673345f`), 6/13 критов A1 закрыто, 2 ужесточены. Добавлены блоки `C-migration` (✅) и `A1-fixups` (⬜) в tracker. Сессия `parallel-orbiting-lamport`.
- 2026-05-06 — выполнен блок **A1-fixups** (Opus 4.7, сессия `precious-wigderson`): IDOR (category_id/counterpart_id/parent_id) в CRUD и sync, mass-assignment whitelist, host-header injection (BASE_URL), PII в логах (DEBUG + email mask), `/docs` gate, audio size + MIME whitelist, `--forwarded-allow-ips`, `EmailStr`. Verified curl-сценариями.
- 2026-05-06 — выполнен объединённый блок **C1 + C2** (Opus 4.7, сессия `giggly-dragon`): аудит AI-слоя (prompt engineering + cost & latency). Отчёт `audit/C1_C2_ai_layer.md`: 5 🔴 / 10 🟡 / 6 🟢 findings. Главные направления для C1+C2-fixups: prompt caching, retry/идемпотентность на клиенте, активация `Device.ai_requests_today` против trial-bypass, `max_tokens` для `/parse-audio`, LIMIT для `_load_user_mappings`, usage-логирование как baseline. Status tracker: C1, C2 → ✅ Done, добавлен блок `C1+C2-fixups` (⬜).
- 2026-05-07 — стартован блок **C1+C2-fixups** (Opus 4.7, сессия `nervous-dewdney`): реализован **M6** — usage-логирование AI-вызовов (`_log_ai_usage` в `backend/app/api/v1/ai.py`), включая retry-цикл `_call_ai_text` и `_call_ai_audio`. Лог пишется на INFO с user_id, mode, prompt/completion/total/cached. DB-персистенция вынесена в новый блок `E1` (см. ниже). Добавлены: раздел `### E. Future work` с блоком **E1** (AI usage telemetry & admin dashboard, поверх M6, требует D1/Alembic), пункт 10 в «Рекомендуемый порядок выполнения», строка `E1 ⬜ TODO` в Status tracker. Status tracker: `C1+C2-fixups` → 🔄 In progress.
- 2026-05-07 — продолжение блока **C1+C2-fixups** (Opus 4.7): закрыты быстрые caps **#4** (`max_tokens=1024` в `_call_ai_audio`), **#5** (LIMIT `AI_MAPPINGS_PROMPT_LIMIT=30` в `_load_user_mappings` + cleanup `> AI_MAPPINGS_TOTAL_LIMIT=200` в `upsert_mapping` + INFO-лог `len(mappings)` в обоих парсерах + детерминированная вторичная сортировка по `updated_at`), **#7** (`max_length=200` на `categories`/`counterparts` в `ParseTextRequest` + руками в `parse_audio`-Form-парсинге + клиентский top-50-по-recency фильтр в `DashboardView.aiCategoryDTOs`). Verified: curl-сценарии для #5 (LIMIT держит 30/30, cleanup срабатывает с warn-лог), #7 (201 cats → 422, 200 cats → 200). Status `C1+C2-fixups` остаётся 🔄 In progress (далее: M14 eval-набор → M13 promptlen → C1.3 retry/idempotency → M15 Premium daily-cap). Структурный roadmap-маркер про auto-learn маппинги — в плане сессии (`/Users/fatau/.claude/plans/todo-audit-c1-c2-ai-layer-md-21-imperative-neumann.md`).
- 2026-05-07 — **зафиксирован известный issue для C3** (Opus 4.7): «Конфликт SYSTEM_PROMPT разделов 4 и 5 — preferences перекрывают явный intent юзера в тексте». Реальный кейс на user_id=19 (кефир/«молочные продукты»). Утилита воспроизведения — `backend/dump_prompt.py` + `backend/prompt_user19_kefir.txt`. Подробности и предложение для C3-сессии — в новой подсекции «Известные issues для C3» под C-блоком.
- 2026-05-07 — закрыт **#16** в C1+C2-fixups (Opus 4.7): `temperature=0.1 → 0` в `_call_ai_text` и `_call_ai_audio` (`backend/app/api/v1/ai.py`). Юзер эмпирически проверил на промптах в разных моделях, что на `gemini-2.5-flash-lite` `T=0` даёт стабильно лучшее качество на ru-кейсах. Verified: два одинаковых `/parse` возвращают идентичный JSON.
