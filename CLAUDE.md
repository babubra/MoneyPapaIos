# Monpapaios

Repo layout:
- `backend/` — backend service
- `Monpapa/` — frontend client
- `todo/` — plans and audit reports
- `todo/audit/` — production-readiness audit findings

## Local development setup

**Когда триггерится:** «запусти бэкенд», «localhost», «подними сервер», «симулятор не подключается», «backend не отвечает», «сбрось БД», «свежий старт», «curl /health», «docker compose», или просто перед началом любой работы с backend / iOS-симулятором.

**Архитектура dev-окружения:**
- Backend (FastAPI + Postgres) живёт в Docker на Mac, слушает `localhost:8001`.
- iOS-симулятор настроен ходить на `localhost:8001` (см. `Monpapa/Monpapa/Services/APIConfig.swift`).
- Реальное iPhone-устройство `localhost` не видит — поправь `DEVICE_DEBUG_URL` в APIConfig.
- Production-VPS `45.90.99.67` — **legacy, не используется**. Workflow auto-deploy отключён (`.github/workflows/deploy.yml.disabled`). Новый VPS появится позже.

**Quick-start (90% случаев это всё, что нужно):**
```bash
cd backend
docker compose up -d
curl http://localhost:8001/health   # → 200 OK
```

После этого симулятор iOS работает «из коробки». В DEV_MODE `POST /auth/request-link {"email":"..."}` сразу возвращает user-JWT без отправки писем — это то, что AuthService автоматически подхватывает в DevModeResponse.

**Полная инструкция (smoke-test, troubleshooting, сброс БД, DEV_MODE-флоу, симулятор не видит backend):** [`backend/DEVELOPMENT.md`](backend/DEVELOPMENT.md). Всегда сверяться с ней перед тем как делать ручные правки или диагностировать поломку — там же есть готовые curl/SQL-сниппеты.

**Что нельзя забыть:**
- `backend/.env` в `.gitignore`. Если нет — `cp .env.example .env` и заполнить (особенно `SECRET_KEY` через `openssl rand -hex 32` ≥32 символа, `DEV_MODE=true`, `DEV_HOST_OK=true`).
- При изменении SQLAlchemy-моделей: `docker compose down -v && docker compose up -d --build` (Alembic пока не используется, БД пересоздаётся).
- Перед любым предположением про backend / iOS-flow — проверить актуальное состояние через curl, не верить памяти.

## Тесты (pytest) для AI-слоя

**Когда триггерится:** правка `backend/app/api/v1/ai.py`, `backend/app/core/system_prompt.py`, смена `AI_MODEL`, upgrade `openai`-SDK, или просто перед коммитом любых backend-изменений.

`backend/tests/` — постоянная pytest-инфраструктура (создана в сессии M14, 2026-05-11). Два слоя: mock-тесты (без сети, <1s) + golden-тесты на реальный aitunnel (~20s, ~$0.03 за прогон). Текущее состояние: 57 passed, 4 xfailed.

**Полная инструкция (структура, когда что прогонять, что значат xfail-маркеры, как добавить кейс):** [`backend/tests/README.md`](backend/tests/README.md). Перед любой правкой AI-слоя — читать первым делом.

Минимум:
```bash
cd backend && source venv/bin/activate
pytest tests/ --ignore=tests/golden  # быстро, без сети
pytest tests/                         # полно, с aitunnel (нужен AITUNNEL_API_KEY в .env)
```

## Auth model migration (active decision)

Приложение мигрирует на **обязательную авторизацию** (Sign in with Apple + magic-link fallback) с AI trial и платной sync. План: **[`todo/auth_model_C_migration.md`](todo/auth_model_C_migration.md)**.

Это решение влияет на любые задачи, связанные с auth, sync, AI-квотами и онбордингом. Прежде чем фиксить такие места — свериться с планом миграции.

## Production readiness audit

Идёт постепенный аудит готовности к проду. Глобальный план:
**[`todo/claude_code_opus_4.7_plan.md`](todo/claude_code_opus_4.7_plan.md)**

Чтобы продолжить аудит в новой сессии:
> "Прочитай `todo/claude_code_opus_4.7_plan.md` и начни с блока **<ID>**. Отчёт положи в `todo/audit/<ID>_<name>.md`."

Правила аудита:
- В сессиях аудита код **НЕ правится**, только отчёты в `todo/audit/`
- Формат отчёта описан в плане (severity 🔴/🟡/🟢, ссылка на `файл:строка`, секция "Что не покрыли")
- После каждой сессии — обновить status tracker в плане
