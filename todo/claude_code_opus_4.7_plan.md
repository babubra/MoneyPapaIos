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
| **C1+C2-fixups** | 🔄 In progress | 2026-05-07 (Opus 4.7) | M6 (usage-логирование) реализован — baseline для последующих fixups по [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) |
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
