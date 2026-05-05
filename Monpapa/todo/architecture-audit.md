# Архитектурный аудит MonPapa iOS

Систематический аудит архитектуры приложения MonPapa (iOS + FastAPI backend) с выявлением слабых мест по 10 блокам.

---

## 1. Авторизация и аутентификация

### Найденные проблемы:

- **🟡 СРЕДНЕ — Нет refresh-токенов / отзыва JWT.** Access token живёт 30 дней (`ACCESS_TOKEN_EXPIRE_MINUTES=43200`). Нет механизма refresh — при протухании токена пользователь вынужден заново проходить Magic Link. Нет отзыва скомпрометированных токенов (нет blacklist/revocation). Для небольшого iOS-only приложения это не главный blocker перед HTTPS/SECRET_KEY/rate limit, но архитектурно лучше перейти на короткий access token + refresh/session revocation.
  - `@backend/app/core/security.py:19` — `create_access_token` с фиксированным TTL
  - `@backend/app/core/config.py:17` — `ACCESS_TOKEN_EXPIRE_MINUTES: int = 43200`

- **🟡 СРЕДНЕ — DEV_MODE выдаёт токен с `sub=user:{id}`, несовместимый с deps.py.** В проде verify-pin корректно выдаёт device-токен + привязывает device.user_id — один токен работает и для AI (rate limit), и для Sync (user через device). Но DEV_MODE создаёт `create_access_token(subject=f"user:{user.id}")`, а `get_current_device` ищет `Device.device_id == subject` → токен `user:123` не найдёт Device → 401 на Sync/AI. Нужно исправить DEV_MODE на device-токен + привязку.
  - `@backend/app/api/v1/auth.py:147` — `create_access_token(subject=f"user:{user.id}")` — сломано
  - `@backend/app/api/v1/auth.py:275` — `create_access_token(subject=body.device_id)` — корректно

- **🟡 СРЕДНЕ — PIN без brute-force защиты.** `_generate_pin()` = 6 цифр (1M вариантов), но нет rate limit на `/verify-pin`. Злоумышленник может перебрать PIN за разумное время.
  - `@backend/app/api/v1/auth.py:77-79` — `_generate_pin()`
  - `@backend/app/api/v1/auth.py:223-276` — `/verify-pin` без rate limit

- **🟡 СРЕДНЕ — Magic Link token передаётся через query string.** `/auth/verify?token=...` принимает одноразовый токен в URL. Query-параметры часто попадают в access logs, proxy logs, browser history и analytics. Лучше использовать short-lived token + redirect без раскрытия токена в финальном URL или POST-обмен.
  - `@backend/app/api/v1/auth.py`

- **🔴 КРИТИЧНО — `/auth/device` без rate limit → обход AI rate limit и слив бюджета.** Эндпоинт полностью открыт (без авторизации), принимает `device_id` длиной 36 символов, но без проверки формата UUID, создаёт запись `Device` и выдаёт валидный JWT. Это открывает два вектора атаки:
  1. **Обход AI rate limit** — каждый Device имеет отдельный лимит 50 текстовых + 5 аудио запросов/день. Скрипт `for i in range(N): POST /auth/device { random_uuid }` → N валидных JWT → N × 50 AI-запросов/день бесплатно. При стоимости ~$0.001/запрос к Gemini, 1000 фейковых устройств = 50K запросов/день = ~$50/день убытка. Автоматизированный скрипт может генерировать устройства непрерывно.
  2. **Флуд БД** — массовая генерация записей в таблице `devices`, хотя это менее критично чем п.1.
  
  Дополнительные усугубляющие факторы:
  - Нет валидации что `device_id` — реальный UUID (проверяется только длина строки)
  - Нет привязки к IP (один IP может создать неограниченное число устройств)
  - Нет Apple DeviceCheck/App Attest — бэкенд не может отличить реальное iOS-устройство от скрипта
  - `is_blocked` — ручная блокировка post-factum, не предотвращает атаку
  
  - `@backend/app/api/v1/auth.py:99-129` — `/device` endpoint без защиты
  - `@backend/app/api/v1/ai.py` — rate limit привязан к `device.id`, не к IP
  
  **Рекомендуемое решение (двухуровневое):**
  
  1. **Сейчас (~30 мин): Rate limit по IP на `/auth/device`** — макс 5 регистраций устройств с одного IP в час. Реализуется через `slowapi` или in-memory dict. Отсекает 95% автоматизированных атак — скрипт не может генерировать тысячи устройств с одного IP.
  
  2. **Перед продом (~2-3 часа): Apple DeviceCheck** — iOS-приложение при первом запуске вызывает `DCDevice.current.generateToken()`, отправляет токен на бэкенд. Бэкенд верифицирует через Apple API (`https://api.development.devicecheck.apple.com/v1/validate_device_token`). Скрипт без реального iOS-устройства не может сгенерировать валидный DeviceCheck-токен. Это единственный надёжный способ отличить реальное устройство от скрипта.
  
  ⚠️ **CORS не подходит** — это механизм браузера, iOS-приложения его не проверяют. Атакующий вызовет endpoint через curl/Python — CORS не ограничит. API-key в бинарнике — security through obscurity, ключ извлекается за 10 минут.

- **🟢 НИЗКО — Двойная генерация deviceId.** И `AuthService`, и `AIService` независимо создают `deviceId` при отсутствии в Keychain. Возможно состояние гонки при первом запуске.
  - `@Monpapa/Services/AuthService.swift:77-89` и `@Monpapa/Services/AIService.swift:98-105`

---

## 2. Безопасность

### Найденные проблемы:

- **🟡 СРЕДНЕ — CORS `allow_origins=["*"]` в проде.** В `main.py` к `cors_origins_list` добавляется `"*"` — это полностью открывает API для браузерных запросов с любого домена. Для iOS API это не основной защитный механизм (curl/Python CORS не соблюдают), но для backend-конфигурации в проде wildcard нужно убрать.
  - `@backend/app/main.py:60` — `allow_origins=app_settings.cors_origins_list + ["*"]`

- **🔴 КРИТИЧНО — SECRET_KEY с дефолтом в коде.** `SECRET_KEY = "change-me-to-a-long-random-string-at-least-32-chars"` — если .env не задан, приложение запускается с предсказуемым ключом. Нет валидации что ключ изменён.
  - `@backend/app/core/config.py:16`

- **🔴 КРИТИЧНО — HTTP в Debug-режиме.** `APIConfig.baseURL` возвращает `http://45.90.99.67:8001` — открытый HTTP на VPS. Токены передаются в открытом виде. На реальном устройстве в Debug — трафик не зашифрован.
  - `@Monpapa/Services/APIConfig.swift:18`

- **🟡 СРЕДНЕ — Логирование тела ответа с токенами.** `AuthService` логирует полный body ответа включая JWT-токен (`print("[AuthService] 📧 requestMagicLink body: \(bodyStr)")`). В проде токены могут утекать в логи.
  - `@Monpapa/Services/AuthService.swift:131`

- **🟡 СРЕДНЕ — `kSecAttrAccessibleAfterFirstUnlock` для токенов.** Это позволяет читать Keychain до первого разблокирования устройства (e.g., при background fetch). Для JWT-токенов лучше `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  - `@Monpapa/Services/KeychainService.swift:32`

- **🟢 НИЗКО/ПОТЕНЦИАЛЬНО — AI-промпт инъекция через `custom_prompt`.** `build_ai_prompt()` умеет напрямую вставлять пользовательский `custom_prompt` без санитизации, но в текущем `parse_text`/`parse_audio` это поле не передаётся в prompt. Сейчас это latent risk на будущее: если подключить `custom_prompt` из настроек, нужны ограничения, префикс безопасности и тесты на prompt injection.
  - `@backend/app/core/system_prompt.py:173-174`

- **🟢 НИЗКО — `monpapa.db` (SQLite) в корне backend.** Вероятно артефакт разработки, но файл БД не должен быть в репозитории.
  - `@backend/monpapa.db`

---

## 3. AI/Промпты

### Найденные проблемы:

- **🟡 СРЕДНЕ — Системный промт на английском, а пользовательский ввод на русском.** Промт задаёт правила по-английски, но примеры — на русском. Для мультиязычности это работает, но может путать модель при locale=de/fr/zh и т.д. Примеры в промте только русские.
  - `@backend/app/core/system_prompt.py:3-126`

- **🟡 СРЕДНЕ — `_sanitize_json` убирает `//` комментарии наивно.** Regex `//[^\n]*` удалит URL вроде `https://...` внутри JSON-значений. Маловероятно, но возможно.
  - `@backend/app/api/v1/ai.py:201`

- **🟡 СРЕДНЕ — Полный промт логируется на INFO.** `logger.info(f"... FULL AI PROMPT ... {SYSTEM_PROMPT} ... {user_prompt}")` — промпт с категориями, маппингами, субъектами пользователя логируется целиком на каждом запросе. В проде — утечка пользовательских данных в логи.
  - `@backend/app/api/v1/ai.py:222`

- **🟡 СРЕДНЕ — Пользовательский финансовый текст также попадает в логи.** Помимо полного prompt, backend логирует входной текст, категории и контрагентов. Даже без JWT это персональные финансовые данные, поэтому в проде нужны redaction/уровни логирования.
  - `@backend/app/api/v1/ai.py`

- **🟡 СРЕДНЕ — Нет валидации AI-ответа на схему.** Результат AI парсится как `dict` и возвращается клиенту «как есть». Нет проверки что обязательные поля (`status`, `type`) присутствуют и корректны. Некорректный AI-ответ может сломать клиент.
  - `@backend/app/api/v1/ai.py:368-373`

- **🟢 НИЗКО — Аудио-парсинг без retry.** `_call_ai_audio` не имеет retry-логики при невалидном JSON, в отличие от `_call_ai_text` (2 попытки).
  - `@backend/app/api/v1/ai.py:269-327`

---

## 4. Синхронизация и офлайн

### Найденные проблемы:

- **🟡 СРЕДНЕ/ВЫСОКО — Sync не атомарен end-to-end.** `sync()` в SyncService.swift делает push (2 фазы) + pull + apply + save как отдельные шаги. Если приложение убить посередине — данные могут быть частично отправлены или частично применены локально. На backend один HTTP-запрос коммитится транзакционно через session dependency, но `sync_batch` ловит ошибки отдельных операций и продолжает, поэтому логически batch может завершиться частичным успехом.
  - `@Monpapa/Services/SyncService.swift:136-241`

- **🟡 СРЕДНЕ — Last-write-wins без уведомления пользователя.** При конфликте (два устройства редактируют одну запись) — серверная версия тихо побеждает. Пользователь не знает что его данные перезаписаны.
  - `@backend/app/api/v1/sync.py:463-473`

- **🟡 СРЕДНЕ — `applyPulledChanges` неоптимален на больших наборах.** Это не везде классический N+1, но есть повторные fetch/линейные `first(where:)` по массивам моделей. При большом количестве данных лучше заранее построить словари `clientId/serverId -> model`.
  - `@Monpapa/Services/SyncService.swift:502-696`

- **🟡 СРЕДНЕ — DebtPayment не имеет `updated_at` на сервере.** `DebtPayment` в моделях БД не имеет `updated_at` (только `created_at`), но iOS-клиент использует `createdAt` как `updatedAt` для sync. Это ломает LWW и выборку изменений для платежей после создания.
  - `@backend/app/db/models.py:291-313` — нет `updated_at` у `DebtPayment`
  - `@Monpapa/Services/SyncService.swift:385` — `updatedAt: p.createdAt`

- **🟡 СРЕДНЕ — Нет пагинации в GET /changes.** При первом sync (since=1970) сервер отдаёт ВСЕ записи пользователя. Для активного пользователя с тысячами транзакций — огромный payload, возможен OOM.
  - `@backend/app/api/v1/sync.py:534-581`

- **🟢 НИЗКО — `lastSyncAt` хранится в Keychain.** Это не секрет — обычный timestamp. Keychain избыточен для этого, но работает.

- **🟡 СРЕДНЕ — `SyncOperation.data` фильтруется blacklist-ом, а не whitelist-ом.** `PROTECTED_FIELDS` защищает часть полей, но допустимые поля не заданы per entity. Лучше валидировать `data` через Pydantic-схемы/allowlist для каждой сущности, иначе клиент может прислать неожиданные поля и получить 500 или некорректную запись.
  - `@backend/app/api/v1/sync.py`

---

## 5. База данных и модели

### Найденные проблемы:

- **🔴 КРИТИЧНО — Нет миграций БД.** `Base.metadata.create_all` при каждом старте — создаёт таблицы если их нет, но НЕ изменяет схему при изменении моделей. Любое изменение модели (новая колонка, изменение типа) требует ручного ALTER TABLE или пересоздания БД с потерей данных.
  - `@backend/app/main.py:30-31` — `conn.run_sync(Base.metadata.create_all)`

- **🟡 СРЕДНЕ — `CategoryMapping.category_id` — строка без FK.** Хранит `client_id` категории (UUID), но без FK constraint. Если категория удалена — маппинг указывает в никуда. Нет cleanup.
  - `@backend/app/db/models.py:358` — `category_id: Mapped[str] = mapped_column(String(36), nullable=False)`

- **🟡 СРЕДНЕ — Нет unique constraint на `(user_id, item_phrase)` в CategoryMapping.** Документация говорит «UNIQUE на (user_id, item_phrase)», но в модели этого нет. Возможны дубли маппингов.
  - `@backend/app/db/models.py:346-369`

- **🟢 НИЗКО — `DebtPayment` не имеет `user_id`.** Хотя это корректно (доступ через debt), это усложняет прямые запросы и требует JOIN.

- **🟡 СРЕДНЕ — Глобальная уникальность `client_id` вместо уникальности в рамках пользователя.** Для offline-first схемы безопаснее уникальные индексы вида `(user_id, client_id)`. Глобальный UUID практически не должен конфликтовать, но архитектурно это смешивает namespace пользователей и усложняет восстановление/импорт данных.

- **🟡 СРЕДНЕ — Нет DB-level уникальности для дедупликации имён/маппингов.** Часть дедупликации делается в коде (`SELECT` перед `INSERT`), но без уникального constraint остаются race conditions при параллельных запросах.

---

## 6. Мультиязычность (i18n)

### Найденные проблемы:

- **🟡 СРЕДНЕ — Только 2 языка в UI, но 12 в AI-промте.** `LocalizationManager.supportedCodes = ["ru", "en"]`, но `_LOCALE_MAP` в system_prompt.py содержит 12 языков. Пользователь не может выбрать de/fr/zh в UI, но AI будет отвечать на этих языках если locale передан.
  - `@Monpapa/Services/LocalizationManager.swift:11`
  - `@backend/app/core/system_prompt.py:130-143`

- **🟡 СРЕДНЕ — Смена языка требует перезапуска приложения.** `LocalizationManager.apply()` пишет в `AppleLanguages` — это влияет только на следующий запуск. Текущая сесся не обновляется полностью.
  - `@Monpapa/Services/LocalizationManager.swift:20-32`

- **🟡 СРЕДНЕ — `effectiveLocale()` маппит на конкретные регионы.** `ru` → `ru_RU`, `en` → `en_US`. Это неправильно для пользователей из UK (`en_GB`), Австралии и т.д. Формат дат/чисел будет американский.
  - `@Monpapa/Services/LocalizationManager.swift:41-47`

- **🟢 НИЗКО — 108KB Localizable.xcstrings.** Большой файл, но это норма для xcstrings-формата. Нужно проверить полноту переводов (не все ключи могут иметь en-перевод).

---

## 7. API-слой и бэкенд

### Найденные проблемы:

- **🟡 СРЕДНЕ — `/docs` и `/redoc` доступны в проде.** Swagger UI открыт по умолчанию на `/docs`. В проде это раскрывает структуру API, но само по себе не является критической уязвимостью при корректной auth/rate-limit/secret-конфигурации.
  - `@backend/app/main.py:53-54`

- **🟡 СРЕДНЕ — Пагинация есть не во всех CRUD-эндпоинтах.** `GET /transactions` уже имеет `limit/offset`, но `GET /categories`, `GET /counterparts`, `GET /debts` возвращают все записи без лимита. При большом объёме данных — перегрузка памяти и сети.
  - `@backend/app/api/v1/transactions.py` — пагинация есть
  - `@backend/app/api/v1/categories.py`, `counterparts.py`, `debts.py` — пагинации нет

- **🟡 СРЕДНЕ — `SyncOperation.data` — `dict[str, Any]` без валидации.** Клиент может отправить произвольные данные в `data` — нет типизации по entity. Единственная защита — `PROTECTED_FIELDS`, но нет whitelist-а разрешённых полей.
  - `@backend/app/api/v1/sync.py:44`

- **🟡 СРЕДНЕ — Нет глобального rate limiting.** Rate limit есть только на AI-эндпоинтах. Sync, auth, CRUD — без ограничений. Возможен DoS.
  - Нет middleware для rate limiting в `@backend/app/main.py`

- **🟡 СРЕДНЕ — AI rate limit неатомарный.** Лимит увеличивается через чтение/изменение полей `Device`. При параллельных запросах возможны race conditions и превышение лимита. Для бюджетных ограничений лучше атомарный SQL update/lock или отдельная таблица usage.

- **🟢 НИЗКО — `joinedload` импортирован но не используется.** В sync.py: `from sqlalchemy.orm import joinedload` — не используется.
  - `@backend/app/api/v1/sync.py:19`

---

## 8. UI/UX архитектура

### Найденные проблемы:

- **🟡 СРЕДНЕ — Синглтоны вместо DI.** `AuthService.shared`, `AIService.shared`, `SyncService` через init — нет dependency injection. Тестирование затруднено, View жёстко привязаны к синглтонам.

- **🟡 СРЕДНЕ — Огромные View-файлы.** `AddTransactionSheet.swift` (30KB), `DashboardView.swift` (23KB), `TransactionListView.swift` (21KB) — нарушение SRP. Сложно поддерживать и тестировать.

- **🟡 СРЕДНЕ — `@MainActor` на сервисах.** `AIService` и `AuthService` — `@MainActor`, хотя сетевые запросы асинхронны. Это блокирует UI при операциях с Keychain (которые синхронны в MainActor).

- **🟢 НИЗКО — `print()` вместо `MPLog` в SyncService и AuthService.** Часть логирования использует `print()`, часть — `os.Logger`. Несогласованность.
  - `@Monpapa/Services/SyncService.swift:80`, `@Monpapa/Services/AuthService.swift:124`

---

## 9. Обработка ошибок и логирование

### Найденные проблемы:

- **🟡 СРЕДНЕ — Ошибки SyncService теряют контекст.** При ошибке sync — `status = .error(error.localizedDescription)` — теряется тип ошибки. UI не может различить сетевую ошибку, ошибку авторизации и ошибку данных.
  - `@Monpapa/Services/SyncService.swift:229-241`

- **🟡 СРЕДНЕ — `try? await Task.sleep` в retry AuthService.** Ошибка при `Task.sleep` проглатывается — retry может молча не сработать.
  - `@Monpapa/Services/AuthService.swift:269`

- **🟡 СРЕДНЕ — Нет структурированного логирования на бэкенде.** Логи — простой `logging.basicConfig` с форматированием через f-strings. Нет request ID, нет correlation ID для трейсинга между запросами.

- **🟢 НИЗКО — MPLog покрывает не все модули.** Нет логгеров для SyncService, StatsService, SettingsView — только AI-related категории.

---

## 10. Конфигурация и деплой

### Найденные проблемы:

- **🔴 КРИТИЧНО — Нет HTTPS на VPS.** Debug-режим использует HTTP на `45.90.99.67:8001`. Release URL `https://api.monpapa.app` — TODO, домен не настроен.
  - `@Monpapa/Services/APIConfig.swift:18-22`

- **🔴 КРИТИЧНО — PostgreSQL порт 5432 открыт наружу.** В `docker-compose.yml` порт 5432 проброшен на `0.0.0.0:5432`. Любой может подключиться к БД извне. Дефолтные креды `monpapa:monpapa_dev_secret` — тривиально подобрать.
  - `@backend/docker-compose.yml:12` — `ports: "5432:5432"`

- **🔴 КРИТИЧНО — Uvicorn напрямую в интернет без reverse proxy.** Нет nginx — нет SSL-терминации, нет rate limiting, нет статики, нет gzip, нет request logging. Uvicorn не предназначен для обслуживания трафика напрямую.
  - `@backend/docker-compose.yml:30` — `ports: "8001:8001"` на `0.0.0.0`
  - `@backend/Dockerfile:19` — `CMD uvicorn ... --host 0.0.0.0`

- **🟡 СРЕДНЕ — CI/CD неполный: деплой есть, тестов/миграций нет.** В репозитории есть `.github/workflows/deploy.yml`, который деплоит backend на VPS через SSH. Но workflow не запускает тесты, lint/type-check, сборку iOS, миграции БД и rollback.
  - `@.github/workflows/deploy.yml`

- **🟡 СРЕДНЕ — Docker без health check.** `Dockerfile` не определяет HEALTHCHECK для backend-контейнера. PostgreSQL имеет healthcheck, но backend — нет. Docker не знает когда backend готов.
  - `@backend/Dockerfile`, `@backend/docker-compose.yml`

- **🔴 КРИТИЧНО — Prod compose выглядит как dev compose.** Текущий deploy workflow запускает `docker compose up --build -d`, а compose монтирует исходники и запускает backend с `--reload`. Если этот compose используется на VPS как prod, backend работает в dev-режиме, с лишним file watcher и непредсказуемыми live-изменениями из volume.
  - `@backend/docker-compose.yml`
  - `@.github/workflows/deploy.yml`

- **🟡 СРЕДНЕ — Две версии MonPapa на одном сервере.** На VPS крутятся `monpapa-*` (текущая) и `monpap-*` (старая) контейнеры одновременно. Старая БД (`monpap-db-1`) не проброшена, но старый backend (`monpap-backend-1`) и frontend (`monpap-frontend-1`) работают. Нет cleanup старых контейнеров.
  - `monpap-frontend-1` слушает порт 10443 — непонятно зачем

- **🟡 СРЕДНЕ — Xray занимает порты 80 и 443.** VPN-прокси (xray + x-ui) занимает стандартные HTTP/HTTPS порты. На текущем сервере невозможно поставить nginx на 80/443 для SSL-терминации без конфликта.

- **🟢 НИЗКО — `monpapa.db` (SQLite) в репозитории.** Артефакт разработки, не должен быть в git.

---

### Деплой на чистый сервер — пошаговый план

> Рекомендации по развёртыванию MonPapa на чистом VPS с учётом найденных проблем.

#### Шаг 1: Подготовка сервера

```bash
# Обновление
apt update && apt upgrade -y

# Docker + Docker Compose
curl -fsSL https://get.docker.com | sh

# Nginx + Certbot
apt install -y nginx certbot python3-certbot-nginx

# Файрвол — открыть только нужное
ufw allow 22/tcp      # SSH
ufw allow 80/tcp      # HTTP → redirect to HTTPS
ufw allow 443/tcp     # HTTPS
ufw enable
# НЕ открывать 5432, 8001 — они должны быть закрыты
```

#### Шаг 2: DNS

```
A-запись:  api.monpapa.app  →  IP сервера
```

#### Шаг 3: Docker Compose (исправленный)
Ключевые изменения относительно текущего:
- **Порты привязаны к localhost** — `127.0.0.1:8001:8001` (uvicorn доступен только nginx)
- **PostgreSQL не проброшен наружу** — убрать `ports: "5432:5432"`
- **Backend healthcheck** — `/health` endpoint уже есть
- **Env-валидация** — приложение не стартует с дефолтным SECRET_KEY
- **Prod command** — без `--reload` и без volume mount исходников

```yaml
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    # НЕ пробрасываем порт наружу!
    # ports: — убрано
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 5s
      timeout: 3s
      retries: 5

  backend:
    build: .
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:8001:8001"  # ← только localhost!
    env_file: .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  pgdata:
```

#### Шаг 4: Nginx reverse proxy

```nginx
server {
    listen 80;
    server_name api.monpapa.app;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.monpapa.app;

    ssl_certificate     /etc/letsencrypt/live/api.monpapa.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.monpapa.app/privkey.pem;

    # SSL hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

#### Шаг 5: SSL сертификат

```bash
certbot --nginx -d api.monpapa.app
# Автоматический renewal уже настроен через systemd timer
```

#### Шаг 6: Кодовые фиксы (перед деплоем)

| Фикс | Файл | Описание |
|------|------|----------|
| CORS убрать `+ ["*"]` | `backend/app/main.py:60` | Только конкретные origins |
| Отключить `/docs` в проде | `backend/app/main.py:53-54` | `docs_url=None, redoc_url=None` если не DEV_MODE |
| Валидация SECRET_KEY | `backend/app/core/config.py` | Проверка что ключ ≠ дефолтный при старте |
| Dockerfile healthcheck | `backend/Dockerfile` | `HEALTHCHECK CMD curl -f http://localhost:8001/health` |
| Uvicorn workers | `backend/Dockerfile:19` | `--workers 2` для продакшна |
| APIConfig Release URL | `Monpapa/Services/APIConfig.swift:21` | Убрать TODO, подтвердить домен |
| Убрать dev-режим из prod compose | `backend/docker-compose.yml` | Без `--reload`, без volume mount исходников |

#### Шаг 7: Мониторинг (рекомендация)

- **Логи:** `docker compose logs -f backend` → настроить rotation
- **Health:** cron `curl -sf http://127.0.0.1:8001/health || alert`
- **Бэкапы БД:** cron `pg_dump ... | gzip > /backup/db_$(date +%Y%m%d).sql.gz`

---

## Проверка и корректировки аудита

- **Подтверждено:** основные риски по HTTPS, открытому PostgreSQL, дефолтному `SECRET_KEY`, `/auth/device`, логированию токенов/prompt, отсутствию миграций, проблемам sync и неполной валидации `SyncOperation.data` подтверждаются кодом.
- **Понижена критичность:** refresh-токены, CORS wildcard, открытые `/docs`, end-to-end атомарность sync и `custom_prompt` не должны идти в один ряд с открытой БД/HTTP/секретом по умолчанию.
- **Исправлены неточности:** CI/CD pipeline есть, но неполный; `GET /transactions` имеет `limit/offset`, но другие CRUD endpoints — нет; `/auth/device` проверяет длину `device_id`, но не UUID-формат; `applyPulledChanges` не везде классический N+1, но всё равно неоптимален.
- **Добавлены пропущенные риски:** prod compose похож на dev compose (`--reload`, volume mount), AI rate limit неатомарный, финансовый текст попадает в логи, Magic Link token идёт через query string, глобальная уникальность `client_id` и отсутствие DB-level constraints оставляют race conditions.

---

## Сводная таблица

| # | Проблема | Блок | Приоритет |
|---|---------|------|-----------|
| 1 | Нет refresh-токенов / отзыва JWT | Авторизация | 🟡 Средне |
| 2 | DEV_MODE: токен `user:{id}` не резолвится через get_current_device | Авторизация | 🟡 Средне |
| 3 | PIN без brute-force защиты | Авторизация | 🟡 Средне |
| 4 | Magic Link token в query string | Авторизация | 🟡 Средне |
| 5 | `/auth/device` без rate limit → обход AI лимитов и слив бюджета | Авторизация | 🔴 Критично |
| 6 | Двойная генерация `deviceId` | Авторизация | 🟢 Низко |
| 7 | CORS `allow_origins=["*"]` в проде | Безопасность | 🟡 Средне |
| 8 | SECRET_KEY с предсказуемым дефолтом | Безопасность | 🔴 Критично |
| 9 | HTTP/нет HTTPS на VPS | Безопасность/Конфигурация | 🔴 Критично |
| 10 | Логирование тела ответа с токенами | Безопасность | 🟡 Средне |
| 11 | Keychain accessibility level | Безопасность | 🟡 Средне |
| 12 | AI custom_prompt injection как будущий риск | Безопасность | 🟢 Низко/потенциально |
| 13 | `monpapa.db` в репозитории | Безопасность/Конфигурация | 🟢 Низко |
| 14 | Системный prompt/примеры плохо адаптированы под мультиязычность | AI/Промпты | 🟡 Средне |
| 15 | `_sanitize_json` наивно удаляет `//` | AI/Промпты | 🟢 Низко |
| 16 | Полный prompt в INFO-логах | AI/Промпты | 🟡 Средне |
| 17 | Пользовательский финансовый текст в логах | AI/Промпты | 🟡 Средне |
| 18 | Нет валидации AI-ответа на схему | AI/Промпты | 🟡 Средне |
| 19 | Аудио-парсинг без retry | AI/Промпты | 🟢 Низко |
| 20 | Sync не атомарен end-to-end | Синхронизация | 🟡 Средне/высоко |
| 21 | LWW без уведомления пользователя | Синхронизация | 🟡 Средне |
| 22 | `applyPulledChanges` неоптимален на больших наборах | Синхронизация | 🟡 Средне |
| 23 | `DebtPayment` без `updated_at` — LWW/changes сломаны для платежей | Синхронизация | 🟡 Средне |
| 24 | Нет пагинации в `GET /changes` | Синхронизация | 🟡 Средне |
| 25 | `lastSyncAt` хранится в Keychain | Синхронизация | 🟢 Низко |
| 26 | `SyncOperation.data` без per-entity whitelist/схем | Синхронизация/API | 🟡 Средне |
| 27 | Нет миграций БД | БД/модели | 🔴 Критично |
| 28 | `CategoryMapping.category_id` без FK | БД/модели | 🟡 Средне |
| 29 | `CategoryMapping` без UNIQUE constraint | БД/модели | 🟡 Средне |
| 30 | `DebtPayment` не имеет `user_id` | БД/модели | 🟢 Низко |
| 31 | Глобальная уникальность `client_id` вместо `(user_id, client_id)` | БД/модели | 🟡 Средне |
| 32 | Дедупликация в коде без DB-level constraints | БД/модели | 🟡 Средне |
| 33 | Только 2 языка UI vs 12 в AI | i18n | 🟡 Средне |
| 34 | Смена языка требует перезапуска | i18n | 🟡 Средне |
| 35 | `effectiveLocale()` жёстко маппит регионы | i18n | 🟡 Средне |
| 36 | `/docs` и `/redoc` открыты в проде | API | 🟡 Средне |
| 37 | Пагинация есть не во всех CRUD-эндпоинтах | API | 🟡 Средне |
| 38 | Нет глобального rate limiting | API | 🟡 Средне |
| 39 | AI rate limit неатомарный | API | 🟡 Средне |
| 40 | Неиспользуемый `joinedload` импорт | API | 🟢 Низко |
| 41 | Синглтоны вместо DI | UI/UX | 🟡 Средне |
| 42 | Огромные View-файлы | UI/UX | 🟡 Средне |
| 43 | `@MainActor` на сетевых сервисах | UI/UX | 🟡 Средне |
| 44 | `print()` вместо единого logger | UI/UX/Логирование | 🟢 Низко |
| 45 | Ошибки SyncService теряют контекст | Логирование | 🟡 Средне |
| 46 | `try? await Task.sleep` в retry | Логирование | 🟢 Низко |
| 47 | Нет структурированного backend-логирования | Логирование | 🟡 Средне |
| 48 | MPLog покрывает не все модули | Логирование | 🟢 Низко |
| 49 | PostgreSQL порт 5432 открыт наружу | Конфигурация | 🔴 Критично |
| 50 | Uvicorn напрямую в интернет без reverse proxy | Конфигурация | 🔴 Критично |
| 51 | CI/CD неполный: деплой есть, тестов/миграций нет | Конфигурация | 🟡 Средне |
| 52 | Docker без backend healthcheck | Конфигурация | 🟡 Средне |
| 53 | Prod compose выглядит как dev compose | Конфигурация | 🔴 Критично |
| 54 | Две версии MonPapa на сервере (нет cleanup) | Конфигурация | 🟡 Средне |
| 55 | Xray занимает порты 80/443 | Конфигурация | 🟡 Средне |

**Итого после корректировки: 7 критичных, 37 средних/средне-высоких, 11 низких/потенциальных проблем.**
