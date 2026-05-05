# A1: Backend attack surface

> Сессия: 2026-05-04, модель: claude-opus-4-7
> Аудит блока **A1** из [`../claude_code_opus_4.7_plan.md`](../claude_code_opus_4.7_plan.md)
> Код **не правился** — только этот отчёт.

> ## ✅ Update 2026-05-05 — реализована pragmatic-миграция Auth Model C
>
> Коммиты `5384e08`, `4549ee6`, `a23592d`, `673345f`. Закрыто 6/13 findings + 2 ужесточены.
> Полный список изменений: [`../auth_model_C_migration.md`](../auth_model_C_migration.md) (раздел «Связь с production-readiness аудитом»).
>
> **Закрытые findings (отмечены ✅ в карте эндпоинтов и Findings ниже):**
> - 🔴 SECRET_KEY дефолт → fail-fast `field_validator`
> - 🔴 `/auth/device` фабрика device_id → endpoint удалён
> - 🔴 `--reload` в проде → `docker-compose.prod.yml` без `--reload`, `--workers 2`, healthcheck
> - 🟡 CORS wildcard `["*"]` → убран
> - 🟡 dev-скрипты в прод-образе → `.dockerignore`
> - 🟢 Нет healthcheck backend → добавлен в prod-compose
>
> **Ужесточённые (но не полностью закрытые):**
> - 🔴 DEV_MODE auto-login → `@model_validator` ограничивает localhost / `DEV_HOST_OK=true`
> - 🔴 PIN brute-force → IP-rate-limit 10/мин (но multi-IP атака всё ещё возможна)
>
> **Остались (для следующих сессий A1-fixups / A2):**
> - 🔴 IDOR через `category_id` / `counterpart_id` (mass-assignment в CRUD)
> - 🟡 Host-header injection в magic-link
> - 🟡 PII в логах (full AI prompt + raw_text транзакций)
> - 🟡 `/docs`, `/redoc` открыты в проде
> - 🟡 `x-forwarded-proto` без `forwarded_allow_ips`
>
> ⚠️ **Карта эндпоинтов ниже отражает состояние ДО миграции** (момент аудита). После миграции:
> `/auth/device` → 404 (удалён); добавлены `/auth/apple`, `/subscription/{status,verify,webhook}`;
> `/ai/*` теперь требует `require_user` (не device); `POST /sync` гейтится подпиской (402);
> `/auth/me` возвращает дополнительно `subscription_status`, `ai_trial_used`.

## Summary

Бэкенд маленький и аккуратно построен на FastAPI + SQLAlchemy ORM (SQL-injection устранена параметризацией), но **готов к проду НЕ является**. Основные проблемы: (1) `SECRET_KEY` для JWT в `.env` всё ещё литерал `change-me-...` — все когда-либо выпущенные токены подделываются ещё до того, как кто-то узнает наш секрет; (2) полностью открытые анонимные эндпоинты `/auth/device` и `/auth/request-link` без rate-limit / IP-фильтрации позволяют (a) штамповать device_id-ы и сливать AI-квоту, (b) бомбить чужие почтовые ящики; (3) PIN-авторизация уязвима к brute-force (6 цифр, без lockout); (4) CORS настроен с `allow_origins=[..., "*"]` и `allow_credentials=True`, что одновременно избыточно и нарушает спеку; (5) `category_id` / `counterpart_id` в обычных CRUD (transactions, debts) **не валидируются на принадлежность user'у** → IDOR (можно прицепить транзакцию к чужой категории); (6) production-контейнер запускается с `--reload` через `docker-compose.yml`; (7) PII (device_id, email, raw_text транзакций, полный prompt) пишется в `*.log` без ретеншена; (8) Magic-link использует `Host` / `X-Forwarded-Proto` без allow-list → host-header injection и подмена ссылки в письме. SQL-инъекций и обвиснутых `eval/exec` нет.

---

## Карта эндпоинтов

> Источник: [backend/app/main.py:68-77](../../backend/app/main.py)

| Path | Method | Auth | Доступ |
|------|--------|------|--------|
| `/health` | GET | ❌ нет | open |
| `/` | GET | ❌ нет | open |
| `/docs`, `/redoc` | GET | ❌ нет | **open в проде** |
| `/api/v1/auth/device` | POST | ❌ нет | **open** — выпуск JWT по любому UUID |
| `/api/v1/auth/request-link` | POST | ❌ нет | **open** — отправка письма |
| `/api/v1/auth/verify` | GET | ❌ нет (короткий JWT в query) | open |
| `/api/v1/auth/verify-pin` | POST | ❌ нет | open |
| `/api/v1/auth/me` | GET | ✅ `require_user` | user |
| `/api/v1/auth/link-device` | POST | ✅ `require_user` | user |
| `/api/v1/auth/account` | DELETE | ✅ `require_user` | user |
| `/api/v1/auth/logout` | POST | ❌ нет (no-op) | open |
| `/api/v1/ai/parse` | POST | ✅ `require_device` (Bearer) | device |
| `/api/v1/ai/parse-audio` | POST | ✅ `require_device` (Bearer) | device |
| `/api/v1/ai/mapping` | POST | ✅ `require_device` | device (skip если не залогинен) |
| `/api/v1/categories` | GET/POST | ✅ `require_user` | user |
| `/api/v1/categories/{id}` | PUT/DELETE | ✅ `require_user` | user |
| `/api/v1/transactions` | GET/POST | ✅ `require_user` | user |
| `/api/v1/transactions/{id}` | PUT/DELETE | ✅ `require_user` | user |
| `/api/v1/transactions/summary` | GET | ✅ `require_user` | user |
| `/api/v1/counterparts` | GET/POST | ✅ `require_user` | user |
| `/api/v1/counterparts/{id}` | PUT/DELETE | ✅ `require_user` | user |
| `/api/v1/debts` | GET/POST | ✅ `require_user` | user |
| `/api/v1/debts/{id}` | PUT/DELETE | ✅ `require_user` | user |
| `/api/v1/debts/{id}/payments` | POST | ✅ `require_user` | user |
| `/api/v1/settings` | GET/PUT | ✅ `require_user` | user |
| `/api/v1/sync` | POST | ✅ `require_user` | user |
| `/api/v1/sync/changes` | GET | ✅ `require_user` | user |

Иерархия Auth-зависимостей: `get_current_device` → `get_current_user` → `require_user` (все в [`backend/app/api/deps.py`](../../backend/app/api/deps.py)). В **DEV_MODE без токена** автоматически выдаётся доступ к dev-пользователю — корректно гейтится `settings.DEV_MODE`, но если флаг случайно зальётся в прод (см. 🔴 ниже), вход открыт всем.

---

## Findings

### 🔴 Critical

- **JWT `SECRET_KEY` в .env — всё ещё дефолт-плейсхолдер** — `backend/.env:11`, fallback в `backend/app/core/config.py:16`
  - **✅ Закрыт в `5384e08`** — `field_validator` отвергает placeholder и `<32` символов, `.env` ротирован, дефолт удалён.
  - Что: и `.env.example`, и реальный `.env` содержат литерал `SECRET_KEY=change-me-to-a-long-random-string-at-least-32-chars`. Этим же значением заданы дефолты в `Settings`. JWT подписан HS256 с этим хорошо известным секретом.
  - Риск: тривиальная подделка любых токенов (device + user). Захват любых аккаунтов; бесконечная AI-квота через выпуск произвольных device-токенов.
  - Рекомендация: (1) сгенерировать криптослучайные ≥32 байта для prod (`openssl rand -hex 32`); (2) убрать дефолт из `Settings.SECRET_KEY`, выкидывать `ValueError` если он совпадает с placeholder'ом; (3) ротация секрета **инвалидирует все живущие 30-дневные токены** — это нужно ожидать. Дополнительно: добавить `kid` в JWT-header, чтобы будущая ротация была дешёвой.

- **`/api/v1/auth/device` без rate-limit — фабрика бесплатных AI-квот** — [`backend/app/api/v1/auth.py:99-129`](../../backend/app/api/v1/auth.py)
  - **✅ Закрыт в `4549ee6`** — endpoint удалён полностью, `get_current_device` / `require_device` тоже. AI-квота теперь = 50 trial на user (`AI_TRIAL_LIMIT`).
  - Что: эндпоинт принимает любой 36-символьный UUID и возвращает 30-дневный JWT. Никакой проверки IP, fingerprint, attestation. Отсюда rate-limit `AI_RATE_LIMIT_DAILY=50` — фикция: 1000 свежих UUID = 50 000 текстовых AI-запросов/день.
  - Риск: прямой денежный ущерб (AiTunnel токены), DOS на AI-провайдера, мусор в `devices` таблице.
  - Рекомендация: (a) IP-rate-limit на `/auth/device` (например, 30/час/IP) через slowapi или Redis; (b) счётчик `device_registrations_per_ip_per_day`; (c) опциональная App Attest / DeviceCheck (iOS) валидация подписи перед выдачей токена; (d) при превышении — captcha/задержка, а не просто отказ; (e) рассмотреть привязку Bearer-токена к IP с допуском N изменений.

- **DEV_MODE auto-login без токена** — [`backend/app/api/deps.py:39-51, 96-111`](../../backend/app/api/deps.py); запрос-линка [`auth.py:144-148`](../../backend/app/api/v1/auth.py)
  - **🟡 Ужесточён в `5384e08`** — `@model_validator` в `config.py` запрещает `DEV_MODE=true` на не-localhost кроме явного `DEV_HOST_OK=true`. Auto-login юзера логируется на WARNING. Полностью DEV_MODE не убран — он нужен для локальной разработки.
  - Что: при `DEV_MODE=true` без `Authorization`-заголовка автоматически создаётся/возвращается `dev@monpapa.local`-пользователь, а `/auth/request-link` отдаёт `access_token` прямо в JSON. Значение пишется в одну переменную окружения; в `.env` сейчас `DEV_MODE=false`, но защёлки от случайной заливки нет.
  - Риск: разовая ошибка в pipeline (или перепутанный prod-`.env`) → весь API становится open / даёт токены кому угодно. Особенно опасно в сочетании с CORS=`*` и открытым `/docs`.
  - Рекомендация: (1) в `lifespan` бросать ошибку, если `DEV_MODE=true` И хост не `localhost`/`127.*`; (2) логировать `WARNING` баннер при старте в DEV_MODE; (3) убрать DEV_MODE из `.env.example` или сделать его 3-state (`off / local / staging`).

- **PIN-код brute-force** — [`backend/app/api/v1/auth.py:223-247`](../../backend/app/api/v1/auth.py)
  - **🟡 Ужесточён в `4549ee6`** — добавлен IP-rate-limit `pin_verify_limiter` (10/мин/IP, `core/rate_limit.py`). Под multi-IP атаку всё ещё уязвимо (1M вариантов, в теории за минуты при ботнете) — нужен per-email lockout после N неверных попыток.
  - Что: 6-значный PIN, TTL 15 минут. На каждый запрос верификации — простой `SELECT WHERE email=? AND code=?`. Нет (а) счётчика неудачных попыток на email, (б) глобального rate-limit на `/verify-pin`, (в) случайной задержки/блокировки. При 1 000 параллельных попыток в окне 15 мин вероятность угадать ~0.1%, при автоматизации — точно подбирается.
  - Риск: захват аккаунта при знании только e-mail цели.
  - Рекомендация: (a) счётчик `attempts` в `magic_codes`, инвалидация после 5 промахов; (b) IP rate-limit на `/verify-pin`; (c) `MagicCode.used` сейчас вообще не выставляется в `verify-pin` (только удаление при успехе); (d) рассмотреть PIN ≥8 символов с буквами или одноразовые TOTP.

- **IDOR через `category_id` / `counterpart_id` в CRUD** — [`backend/app/api/v1/transactions.py:118-122`](../../backend/app/api/v1/transactions.py), [`debts.py:85-88`](../../backend/app/api/v1/debts.py), `update_*` в тех же файлах
  - **❌ ОСТАЛСЯ** — главный приоритет для следующей сессии (`A1-fixups`). Auth Model C не закрывает: чужой category_id всё ещё можно прицепить через mass-assignment.
  - Что: `Transaction(user_id=user.id, **body.model_dump())` копирует `category_id` без проверки `Category.user_id == user.id`. То же для `Debt.counterpart_id`, `update_transaction.setattr`, `update_debt.setattr`. В `sync.py:402-413` `_resolve_fk_fields` валидирует только когда FK = NULL и резолвит через client_id; явно переданный числовой `category_id` другого юзера попадает в БД.
  - Риск: атакующий, зная числовые id чужих категорий/контрагентов, прицепляет к ним свои транзакции/долги. На чтение это не повлияет (в `list_*` всё ещё фильтруется по `user_id`), но `summary` и аналитика чужой стороны искажаются; либо клиент может «утянуть» имя категории (joinedload в response отдаёт имя). Утечка имени чужой категории/контрагента через `_enrich_category_fields` в `transactions.py:29-42`.
  - Рекомендация: добавить общий `_owns(model, id, user)` helper и вызывать перед setattr; либо whitelist полей в Pydantic-схеме без FK и резолвить FK через `client_id` единообразно (как в `sync._resolve_fk_fields`).

- **Production контейнер запускается с `--reload`** — [`backend/docker-compose.yml:33, 39`](../../backend/docker-compose.yml)
  - **✅ Закрыт в `5384e08`** — создан отдельный `docker-compose.prod.yml` без `--reload` и bind-mount, `--workers 2`, `--proxy-headers`, healthcheck. `.github/workflows/deploy.yml` теперь использует `-f docker-compose.prod.yml`.
  - Что: `command: uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload` + bind-mount `.:/app`. Этот же compose-файл используется в проде — деплой [`/.github/workflows/deploy.yml:33`](../../.github/workflows/deploy.yml) выполняет `docker compose up --build -d` на VPS.
  - Риск: (а) `--reload` не для прода: лишний watcher, не работают graceful shutdown'ы, лишний CPU; (б) bind-mount `.` означает, что любой файл, оказавшийся в `/root/Monpapa/backend/` на VPS, попадает в контейнер; (в) нет `workers > 1` → один процесс на всю нагрузку.
  - Рекомендация: разделить `docker-compose.yml` (dev) и `docker-compose.prod.yml`; в проде убрать `--reload`, убрать volume-mount, поднять `--workers` через gunicorn+uvicornworkers или через `UVICORN_WORKERS`.

### 🟡 Medium

- **CORS: одновременно whitelist + `*` + `allow_credentials=True`** — [`backend/app/main.py:58-64`](../../backend/app/main.py)
  - **✅ Закрыт в `5384e08`** — `+ ["*"]` убран; теперь только `cors_origins_list` из `CORS_ORIGINS`.
  - Что: `allow_origins=app_settings.cors_origins_list + ["*"]`. Браузеры по спеке отбрасывают `*` при `allow_credentials=True`, но в коде явно указан wildcard. Комментарий `# * убрать в prod` остался незакрытым.
  - Риск: фактически отключает Origin-проверку в местах, где cookie/Authorization используются (например, `/api/v1/auth/verify` через ссылку в письме). При локальной отладке фронтенд из произвольного origin может получать токены.
  - Рекомендация: убрать `["*"]`; в проде оставить только `https://app.monpapa.io`-подобные домены; для нативного iOS CORS не нужен, его можно включить только для veb-onboarding страницы.

- **Magic-link использует `Host` и `X-Forwarded-Proto` из запроса без allow-list** — [`backend/app/api/v1/auth.py:175-180`](../../backend/app/api/v1/auth.py)
  - **❌ ОСТАЛСЯ** — фиксить в `A1-fixups`: ввести `BASE_URL` в `Settings`, перестать читать заголовки.
  - Что: `scheme = request.headers.get("x-forwarded-proto", "https"); host = request.headers.get("host", "")`; этот URL вшивается в HTML письма как `verify_url`.
  - Риск: классический host-header injection — атакующий, зная email цели, делает запрос с `Host: attacker.com`, цель получает фишинговую ссылку, переход = передача краденого `magic_token` атакующему. Также `X-Forwarded-Proto: http` понижает scheme.
  - Рекомендация: (a) хардкодить `BASE_URL` (env-var) вместо вычисления; (b) либо middleware `TrustedHost` с allow-list; (c) уверенно установить `forwarded_allow_ips` в uvicorn.

- **`/auth/request-link` без rate-limit → email bombing** — [`auth.py:132-188`](../../backend/app/api/v1/auth.py)
  - **✅ Закрыт в `4549ee6`** — `magic_link_limiter` 5/мин/IP в `core/rate_limit.py`.
  - Что: любой может слать `{ "email": "victim@x.com" }` бесконечно; SMTP-аккаунт будет блокирован Gmail'ом, жертва получает спам, MagicCode-таблица засоряется. Также утечка факта существования email в проверке `allowed_emails_list` (но `allowed_emails_list` сейчас пуст → не используется).
  - Риск: репутационный (Gmail SMTP-блок), DoS на почтовый канал, спам в адрес жертвы.
  - Рекомендация: (a) IP rate-limit (1 запрос/мин/IP, 5/час/IP); (b) rate-limit per-email (1/мин); (c) одинаковый ответ независимо от того, есть ли email в allow-list; (d) HCaptcha/Turnstile перед отправкой — при первом запросе с IP.

- **PII в логах без ретеншена** — [`backend/app/api/v1/ai.py:222, 236, 341-344`](../../backend/app/api/v1/ai.py); [`auth.py:118-120, 266, 270, 316, 338, 353`](../../backend/app/api/v1/auth.py); [`backend/server.log`](../../backend/server.log)
  - **❌ ОСТАЛСЯ** — `ai.py` всё ещё логирует FULL AI PROMPT + raw_text на INFO. Фиксить в C1/C2 (audit AI prompt) или в `A1-fixups`.
  - Что: в `INFO` логе пишутся: полный текст транзакций пользователя (`Купил коврики в машину за 3000`), полный AI prompt (включая список категорий), email, device_id (полностью в auth, обрезается до 8 символов в ai), user_id. `server.log` — 40KB plain-text без ротации в репо (локально).
  - Риск: GDPR/152-ФЗ: персональные данные + финансовая информация в файле без срока хранения. На VPS этот же лог пишется в stdout контейнера → попадёт в любую систему агрегации логов; также `docker logs` будет читать любой, у кого есть SSH.
  - Рекомендация: (a) в проде логировать на DEBUG только содержимое транзакций; (b) маскировать email (`a***@gmail.com`); (c) включить log rotation (logrotate / `--log-config`); (d) централизованный sink (Loki/CloudWatch) с retention.

- **Нет лимита размера тела/файла на `/parse-audio`** — [`backend/app/api/v1/ai.py:376-397`](../../backend/app/api/v1/ai.py)
  - **❌ ОСТАЛСЯ** — фиксить в `A1-fixups`: проверка `audio.size` до чтения, либо `Content-Length` middleware.
  - Что: `audio: UploadFile = File(...)` принимает файл любого размера; `audio.read()` загружает всё в память, потом base64-кодируется (×1.33). Лимит `AI_MAX_AUDIO_SECONDS=30` нигде не валидируется до отправки в AI.
  - Риск: одного запроса с файлом на 1 GB достаточно, чтобы убить процесс OOM. Также бесплатно жжём AI-токены, потому что rate-limit увеличивается ДО проверки размера → попытка без квоты = квота уже скушана. Стоп — на самом деле rate-limit идёт первым (`_check_and_increment_audio_limit` в строке 395), так что финансовый риск ограничен. Память не ограничена.
  - Рекомендация: (a) проверять `Content-Length` в middleware (отклонять >5MB); (b) ограничивать `audio.size` явным `if audio.size > MAX: raise 413`; (c) валидировать `content_type` whitelist (`audio/m4a`, `audio/wav`, `audio/webm`).

- **Mass-assignment через `Model(**body.model_dump())`** — `transactions.py:121`, `debts.py:87`
  - **❌ ОСТАЛСЯ** — связан с IDOR Critical-#5; чинить вместе.
  - Что: Pydantic-схемы `TransactionCreate`/`DebtCreate` сейчас не содержат вредных полей — но при их расширении любое новое поле модели автоматически становится записываемым. Также `update_*` делает `setattr(transaction, field, value)` на основе body без явного whitelisting.
  - Риск: regression-вектор. Пример: добавили `Transaction.user_id` в `TransactionUpdate` (по ошибке) → можно перепривязать чужую транзакцию.
  - Рекомендация: явный whitelist полей при создании/обновлении (как сделано в `sync.PROTECTED_FIELDS`).

- **Schema создаётся через `Base.metadata.create_all` — нет миграций** — [`backend/app/main.py:30-31`](../../backend/app/main.py)
  - **⏸️ Сознательно отложено** — БД droppable пока нет реальных юзеров. Поднять Alembic baseline отдельной сессией перед первым прод-деплоем (см. tracker D1).
  - Что: Alembic в requirements есть, но папки миграций нет. Любая эволюция модели потребует ручного `ALTER TABLE` в проде. Сейчас, например, на проде уже могут быть несоответствия.
  - Риск: данные ломаются при следующем мердже модели; нечем откатиться.
  - Рекомендация: завести `backend/alembic/`, сгенерировать baseline-миграцию из текущих моделей, в `lifespan` заменить `create_all` на запуск `alembic upgrade head` (или вынести в init-job).

- **`/docs` и `/redoc` открыты в проде** — [`main.py:53-54`](../../backend/app/main.py)
  - **❌ ОСТАЛСЯ** — фиксить в `A1-fixups`: `docs_url=None if not DEV_MODE else "/docs"`.
  - Что: `docs_url="/docs"`, `redoc_url="/redoc"` без условия. Атакующему сразу выдан полный список эндпоинтов и схема запросов.
  - Риск: ускоренная разведка; не критично само по себе, но усиливает все остальные дыры.
  - Рекомендация: `docs_url=None if not settings.DEV_MODE else "/docs"`; либо защитить basic-auth.

- **Bearer-токены: 30 дней без refresh / revocation** — [`config.py:17`](../../backend/app/core/config.py), [`security.py`](../../backend/app/core/security.py)
  - **❌ ОСТАЛСЯ** — отложено до A2 (auth lifecycle). Subject-формат токена изменился (`user:{id}`), но lifecycle не тронут.
  - Что: `ACCESS_TOKEN_EXPIRE_MINUTES=43200` (30 дней). При компрометации нет способа отозвать токен (никакой jti/blacklist). `is_blocked` на Device помогает только если токен включает существующее устройство, но не для `user:<id>`-токенов из `/verify` (`auth.py:217`).
  - Риск: украденный JWT работает месяц, и логаут — фейк (`/auth/logout` — no-op).
  - Рекомендация: short access (15 мин) + refresh-token; revocation list по `jti` (или по `users.token_version` инкрементом при логауте).

- **`AITUNNEL_API_KEY` и `SMTP_PASSWORD` в plain-text в `.env` на dev-машине** — [`backend/.env:15, 29`](../../backend/.env)
  - **❌ ОСТАЛСЯ** — secret-manager (Doppler/Bitwarden/SOPS) — задача для D3 (Secrets management). На dev-машине это норма; критично только для прода/CI.
  - Что: оба секрета — рабочие (Gmail App Password `gjcb ufpt cbdo cjfq`, AiTunnel ключ `sk-aitunnel-…`). Файл не в git (`.gitignore` корректен), но лежит plain-text на ноутбуке, в Docker bind-mount, и доступен любому, у кого есть SSH/диск.
  - Риск: ротация при компрометации не автоматизирована; нет аудита использования ключей. Email App Password даёт доступ ко всему почтовому ящику (не ограничен SMTP).
  - Рекомендация: (a) сейчас же отозвать обнаруженный Gmail App Password и AiTunnel API key (после переноса) — они утекли в этот аудит-отчёт; (b) использовать секрет-менеджер (Doppler / Vault / 1Password CLI); (c) для SMTP — отдельный noreply-аккаунт; (d) `.env.example` без реальных значений (в текущем — placeholder'ы корректны).

### 🟢 Low / Nice-to-have

- **Нет security-headers middleware** — `backend/app/main.py`
  - Что: нет `HSTS`, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Content-Security-Policy`. Для нативного iOS-клиента это не критично, но `/api/v1/auth/verify` рендерится в браузере (редирект из письма) и полезно для онбординга.
  - Рекомендация: `secure-headers`/middleware с базовым набором; HTTPS-только cookie если будут вводиться cookie-сессии.

- **`/auth/logout` ничего не делает** — [`auth.py:357-360`](../../backend/app/api/v1/auth.py)
  - Что: возвращает `{"message": "Logged out"}`. Клиент сам стирает токен, но серверной revocation нет.
  - Рекомендация: парная задача к 🟡 «refresh + revocation».

- **`MagicCode.used` никогда не выставляется в `True`** — [`auth.py:223-251`](../../backend/app/api/v1/auth.py)
  - **🟢 Не критично** — `verify_pin` после успеха `delete()`-ит все `MagicCode` для email, поэтому повторное использование невозможно. Поле `used` фактически dead-code; убрать или начать использовать — отдельная задача.
  - Что: после успеха `verify-pin` все коды email просто `DELETE`. Поле `used` мёртвое.
  - Рекомендация: либо удалить поле из модели, либо использовать его и не удалять (для аудита). Сейчас — мёртвый код.

- **Server response leaks DB error in sync** — [`sync.py:341-347`](../../backend/app/api/v1/sync.py)
  - Что: `message=str(e)` в `SyncOperationResult` для любой ошибки. Туда могут попасть SQL-стектрейсы, имена колонок, нарушения FK.
  - Рекомендация: логировать full error на сервере, клиенту отдавать общий код (`"db_error"`) + correlation-id.

- **`request-link`: `Field(..., min_length=3)` вместо `EmailStr`** — [`auth.py:48-49`](../../backend/app/api/v1/auth.py)
  - Что: `email-validator` в requirements, но не используется. Принимаются строки вроде `"abc"`.
  - Рекомендация: `from pydantic import EmailStr`; заменить тип.

- **`monpapa.db` (SQLite) и `*.log` лежат в `backend/`** — [`backend/monpapa.db`](../../backend/monpapa.db), [`backend/server.log`](../../backend/server.log)
  - Что: gitignore корректен, в репозитории их нет. Однако оба попадают в Docker-образ через `COPY . .` (Dockerfile:15) и в bind-mount. SQLite-файл — артефакт ранней разработки до миграции на PostgreSQL.
  - Рекомендация: `.dockerignore` (`venv/`, `*.db`, `*.log`, `.env`); удалить SQLite файл из дерева.

- **`check_cache.py`, `test_db_*.py`, `dev.sh` попадают в прод-образ** — `backend/Dockerfile:15` (`COPY . .`)
  - **✅ Закрыт в `5384e08`** — добавлен `backend/.dockerignore`, исключает dev-скрипты, `*.db`, `*.log`, `.env`, `.git`, `todo/`.
  - Что: dev-скрипты копируются в production-контейнер. Не уязвимости сами по себе, но `check_cache.py` инициализирует AsyncOpenAI клиент с реальным ключом — добавляет attack surface, если кто-то получит RCE.
  - Рекомендация: `.dockerignore` или multi-stage build.

- **Деплой `git reset --hard origin/main` без проверки подписи** — [`/.github/workflows/deploy.yml:27`](../../.github/workflows/deploy.yml)
  - Что: VPS жёстко перетягивает `origin/main`. SSH-ключ деплоя в GH-secrets (хорошо), но нет supply-chain check (signed tags / verified commits).
  - Рекомендация: переключиться на тэги, требовать `gpg --verify`, либо OIDC + подписанные образы.

- **`x-forwarded-proto` доверие без `forwarded_allow_ips`** — [`auth.py:176`](../../backend/app/api/v1/auth.py); uvicorn без `--proxy-headers` или `--forwarded-allow-ips`
  - **🟡 Частично закрыт в `5384e08`** — prod-compose теперь запускает uvicorn с `--proxy-headers`. Но `forwarded_allow_ips` всё ещё не задан, и `auth.py:176` всё ещё читает `request.headers.get("x-forwarded-proto")` напрямую. Полный фикс — в `A1-fixups` вместе с host-header injection.
  - Что: uvicorn по умолчанию читает `X-Forwarded-*` только при `--proxy-headers`. Сейчас флаг не передаётся, но код всё равно его читает — означает, что заголовок принимается как есть, без проверки доверенного прокси.
  - Рекомендация: связано с 🟡 host-header injection. Зафиксировать `BASE_URL` в env, перестать читать заголовки.

- **Нет healthcheck для backend в docker-compose** — `docker-compose.yml`
  - **✅ Закрыт в `5384e08`** — `docker-compose.prod.yml` имеет healthcheck для backend (curl `/health` каждые 30s). Dev-compose без healthcheck — сознательно (быстрее старт).
  - Что: только у `db` есть `healthcheck`. Если backend зависает — внешний LB / restart-policy не понимает, нужно ли его перезапустить.
  - Рекомендация: `healthcheck: curl -f http://localhost:8001/health` + `restart: unless-stopped` (последнее уже есть).

---

## Что не покрыли

- **Алгоритмическая корректность Auth**: не проверял interactions между `verify-pin` и `link-device` в edge-cases (race-condition на `device.user_id`, два устройства одновременно перепривязываются).
- **Sync conflicts**: `_sync_update` использует last-write-wins по `updated_at`, но не покрыта проверка clock-skew клиента и атак с искусственно высоким `updated_at`. Нужна отдельная сессия по `sync.py`.
- **Загрузка вложений** (`Transaction.attachment_path`): поле есть, но ни один эндпоинт его не пишет/не читает. Стоит подтвердить, что фича не «полузакрытая».
- **Performance / DoS на тяжёлых query**: не проверял индексы (есть `index=True` на `user_id`/`client_id`/`device_id`/`email`), полнотекстовый `ilike` поиск в `transactions.py:89` без gin-индекса, `extract(year/month, …)` без functional index — всё это в **A3 (Data layer)**.
- **AI cost leak**: вопрос «сколько стоит каждая 50я попытка» — это **C1/C2**.
- **Frontend, как именно использует токен**: пишется ли он в Keychain корректно — это **B-блок**.
- **Сетевая инфраструктура VPS**: nginx/Caddy/firewall перед FastAPI, TLS-конфиг, fail2ban — это **D1/D3**.
- **Зависимости** (`requirements.txt`): не делал `pip-audit` / CVE-скан. Версии примерно свежие (FastAPI 0.115, SQLAlchemy 2.0.36), но без аудита.
- **CSRF**: не покрыто — для чисто Bearer-API это не нужно, но если будут добавляться cookie-сессии для веб, нужно вернуться.
- **Apple Sign in** (`User.apple_user_id`): поле есть, но эндпоинт не виден — вероятно, не реализован. Это либо TODO в коде, либо отсутствие фичи.
  - **✅ Реализован в `4549ee6`** — `POST /api/v1/auth/apple` + `core/apple_auth.py` (JWKS-проверка). Runtime-сторона iOS требует Apple Developer Program + entitlement (заглушка с graceful fallback пока).
