# Backend — локальная разработка

> Цель: поднять backend в Docker на Mac, чтобы iOS-симулятор мог стучаться на `http://localhost:8001`.

## TL;DR

```bash
cd /Users/fatau/TEST/Monpapaios/backend
docker compose up -d
curl http://localhost:8001/health   # → {"status":"ok",...}
```

iOS-симулятор уже настроен ходить на `localhost:8001` (см. `Monpapa/Monpapa/Services/APIConfig.swift`). Ничего больше не нужно.

---

## Архитектура

```
iOS Simulator ──HTTP──► localhost:8001 ──► Docker Compose
                                            ├── monpapa-backend  (FastAPI, uvicorn)
                                            └── monpapa-db        (PostgreSQL 16-alpine)
```

- **`monpapa-backend`** — FastAPI на `0.0.0.0:8001` с `--reload` (dev-режим). Bind-mount `.:/app` — изменения в коде подхватываются без пересборки контейнера.
- **`monpapa-db`** — PostgreSQL, данные в Docker volume `pgdata`. `docker compose down` сохраняет данные, `down -v` удаляет.
- **iOS SwiftData** — отдельная локальная БД в sandbox симулятора, не зависит от Docker.

> Production-конфиг — `docker-compose.prod.yml` (без `--reload`, `--workers 2`, healthcheck, БД не наружу). Для dev не используется.

## Prerequisites

- Docker Desktop запущен (`docker ps` отвечает без ошибки).
- Файл `backend/.env` существует (он в `.gitignore`, не коммитится). Если нет — скопировать `cp .env.example .env` и заполнить:
  - `SECRET_KEY` — обязательно ≥32 символов, не плейсхолдер. Сгенерировать: `openssl rand -hex 32`
  - `AITUNNEL_API_KEY` — для AI-парсинга через aitunnel.ru
  - `AI_MODEL` — например `gemini-2.5-flash-lite`
  - `DEV_MODE=true` + `DEV_HOST_OK=true` — для разработки, чтобы шорткаты работали
  - SMTP-настройки — нужны только если `DEV_MODE=false` и тестируешь реальную доставку Magic Link

## Запуск

```bash
cd backend
docker compose up -d            # поднять в фоне
docker compose logs -f backend  # смотреть логи (Ctrl+C — отвязаться, контейнер продолжит)
docker compose ps               # статус
docker compose down             # остановить (данные БД сохраняются в volume)
docker compose down -v          # остановить + СНЕСТИ БД (используется при смене схемы)
```

## Smoke test

```bash
# 1. Здоровье backend
curl -fsS http://localhost:8001/health
# → {"status":"ok","service":"monpapa-backend","version":"2.0.0"}

# 2. /auth/device должен быть 404 (удалён в Auth Model C)
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8001/api/v1/auth/device
# → 404

# 3. DEV_MODE shortcut — magic-link сразу возвращает токен
TOKEN=$(curl -s -X POST http://localhost:8001/api/v1/auth/request-link \
  -H "Content-Type: application/json" -d '{"email":"test@local"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# 4. /auth/me с этим токеном
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8001/api/v1/auth/me
# → {"id":..., "email":"test@local", "subscription_status":"free", "ai_trial_used":0, ...}
```

## DEV_MODE — что он делает

Включается через `DEV_MODE=true` в `.env`. Эффекты:

| Endpoint / Behavior | Без DEV_MODE | С DEV_MODE |
|---|---|---|
| `POST /auth/request-link` | Шлёт email с PIN, отвечает `{"message": "..."}` | Создаёт юзера, сразу возвращает `{"token": "...", "user_id": N}` |
| `POST /auth/apple` | Реальная JWKS-проверка identity_token | `identity_token == "DEV_STUB"` обходит проверку (apple_sub привязывается к device_id) |
| `get_current_user` без токена | 401 | Auto-login dev-пользователя `dev@monpapa.local` (логируется WARNING) |
| Запуск backend | работает на любом хосте | требует localhost ИЛИ `DEV_HOST_OK=true` (защита от случайного `DEV_MODE=true` в проде) |

`DEV_HOST_OK=true` нужен, потому что в Docker-контейнере `socket.gethostname()` возвращает container ID, а не localhost. На Mac без Docker эта переменная не нужна.

## Сброс БД

При изменении SQLAlchemy-моделей (`backend/app/db/models.py`) Postgres не накатывает изменения автоматически — Alembic пока не используется, схема создаётся через `Base.metadata.create_all` (только для **новых** таблиц). Чтобы получить новую схему:

```bash
docker compose down -v          # ← `-v` сносит volume `pgdata`
docker compose up -d --build    # пересборка + чистая БД
```

## Симулятор не видит backend

Чек-лист если из iOS-приложения 404 / network errors:

1. `docker compose ps` — оба контейнера в статусе `Up`?
2. `curl http://localhost:8001/health` с Mac — отвечает?
3. `Monpapa/Monpapa/Services/APIConfig.swift` — для симулятора стоит `http://localhost:8001`?
4. В Xcode: **Product → Clean Build Folder**, потом пересобрать. iOS кеширует ATS-настройки.
5. Симулятор иногда залипает с DNS — Hardware → Erase All Content and Settings.

> Реальное iPhone в той же Wi-Fi сети `localhost` НЕ видит — для него `localhost` = само устройство. Если нужно тестировать с iPhone, поправь `DEVICE_DEBUG_URL` в `APIConfig.swift` на IP Mac (`192.168.x.x:8001`) и убедись, что Mac firewall пропускает порт 8001.

## Типичные ошибки

### `ValidationError: SECRET_KEY must be ≥32 characters` при старте

Backend упал fail-fast. В `.env` либо нет `SECRET_KEY`, либо короткий, либо начинается с `change-me`. Сгенерировать новый:

```bash
openssl rand -hex 32
```

…и подставить в `.env`. После этого `docker compose down && up -d`.

### `ValueError: DEV_MODE=true on non-localhost host`

В Docker `hostname` это random container ID. Добавь в `.env`:

```
DEV_HOST_OK=true
```

И `docker compose down && up -d`.

### iOS получает 401 при проверке `/auth/me` после magic-link

Проверь, что backend в DEV_MODE (`docker compose exec backend python3 -c "from app.core.config import get_settings; print(get_settings().DEV_MODE)"` должно быть `True`). Без DEV_MODE `/auth/request-link` не отдаёт токен напрямую — нужно реально получить PIN из email и пройти `/auth/verify-pin`.

### iOS получает 402 на `/ai/parse`

Это ожидаемо при `subscription_status="free" AND ai_trial_used >= 50`. iOS открывает PaywallView. Чтобы быстро снять paywall:

```bash
docker compose exec backend python3 -c "
from app.db.session import async_session_maker
from app.db.models import User
from sqlalchemy import update
import asyncio
async def main():
    async with async_session_maker() as db:
        await db.execute(update(User).values(subscription_status='active', ai_trial_used=0))
        await db.commit()
asyncio.run(main())
"
```

Либо тапнуть «Оформить подписку» в PaywallView — DEV-stub `/subscription/verify` поставит юзера в `active` на 30 дней.

### `Connection refused` / порт занят

```bash
lsof -i :8001        # кто слушает 8001
lsof -i :5432        # кто слушает Postgres
docker compose down  # остановить compose
```

Если другой процесс держит порт — поменять mapping в `docker-compose.yml` (`8001:8001` → `8002:8001`) и обновить APIConfig.

## Что про VPS

`45.90.99.67` — старый прод-VPS, **не используется** для разработки. Workflow `.github/workflows/deploy.yml.disabled` не запускается (переименован в `.disabled`). При переезде на новый VPS — отдельная сессия, сейчас можно игнорировать.

См. также:
- [`todo/auth_model_C_migration.md`](../todo/auth_model_C_migration.md) — что закрыто в backend, что осталось
- [`todo/audit/A1_backend_surface.md`](../todo/audit/A1_backend_surface.md) — security findings с inline-метками статуса
