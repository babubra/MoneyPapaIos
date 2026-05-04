# Production Readiness Audit — Global Plan

> Автор: Claude Code (Opus 4.7), сессия от 2026-05-04
> Цель: довести Monpapaios (backend + Monpapa frontend + AI-слой + infra) до production-ready состояния

---

## Контекст

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
| C2 | Cost & latency | Токен-бюджеты, кэширование ответов, выбор модели (Haiku vs Sonnet vs Opus под задачу), батчинг, streaming |
| C3 | Качество ответов | Детерминизм, валидация JSON-выхода, fallback при ошибках/таймаутах, evaluations |

### D. Infra & deploy

| ID | Тема | Что проверяем |
|----|------|---------------|
| D1 | Deploy pipeline | Текущий GitHub Actions deploy, rollback, zero-downtime, health checks |
| D2 | Observability | Логи, метрики, алерты (особенно по AI cost), error tracking |
| D3 | Backup & secrets | БД бэкапы, ротация ключей, где хранятся secrets (env? vault?) |

---

## Рекомендуемый порядок выполнения

По убыванию пользы за токен:

1. **A1** — backend attack surface (фундамент для всего security)
2. **C1 + C2** — AI prompt & cost (горящие деньги)
3. **A2** — auth & rate-limit (закрытие самых опасных дыр из A1)
4. **B1 + B2** — frontend архитектура (техдолг растёт быстрее тут)
5. **B3** — UI smoothness (после B1 часть jank уйдёт сама)
6. **A3, A4** — data, dev/prod (важно, но менее срочно)
7. **C3** — качество AI-ответов
8. **D1–D3** — infra (когда код готов к проду)

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
| A1 | ⬜ TODO | — | — |
| A2 | ⬜ TODO | — | — |
| A3 | ⬜ TODO | — | — |
| A4 | ⬜ TODO | — | — |
| B1 | ⬜ TODO | — | — |
| B2 | ⬜ TODO | — | — |
| B3 | ⬜ TODO | — | — |
| B4 | ⬜ TODO | — | — |
| C1 | ⬜ TODO | — | — |
| C2 | ⬜ TODO | — | — |
| C3 | ⬜ TODO | — | — |
| D1 | ⬜ TODO | — | — |
| D2 | ⬜ TODO | — | — |
| D3 | ⬜ TODO | — | — |

> Обновляй эту таблицу после каждой сессии: ⬜ TODO → 🔄 In progress → ✅ Done

---

## История ревизий плана

- 2026-05-04 — план создан (Opus 4.7), сессия `inspiring-dewdney-4e595d`
