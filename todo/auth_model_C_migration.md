# Auth Model C — миграция на обязательную авторизацию

> Решение принято: 2026-05-04 (диалог с Opus 4.7)
> **Статус: 🟢 Pragmatic implementation done (2026-05-05)** — реализовано всё, что не требует Apple Developer Program. Apple Sign-In + StoreKit оставлены как заглушки с TODO. Коммиты `5384e08`..`673345f` в `main`.
> **Update 2026-05-06:** sync-модель пересмотрена с «WRITE за подпиской» на «sync free unlimited, Premium = AI без лимита» (вариант A — подробности ниже в разделе «Зафиксированные решения»). Терять финансовые данные при переустановке приложения — плохой UX, лимитировать sync — плохая бизнес-этика для финансового приложения.

## ✅ Что сделано в pragmatic-итерации (2026-05-05)

> Полный план реализации: `~/.claude/plans/parallel-orbiting-lamport.md`. Ниже — резюме закрытого скоупа.

**Backend (`5384e08`, `4549ee6`):**
- ✅ SECRET_KEY fail-fast (`field_validator` в `config.py` отвергает placeholder и `<32` символов)
- ✅ Раздельный `docker-compose.prod.yml` без `--reload`, `--workers 2`, `--proxy-headers`, healthcheck, БД не наружу
- ✅ `.dockerignore` — dev-артефакты не попадают в прод-образ
- ✅ DEV_MODE hardening (`@model_validator` запрещает не-localhost кроме явного `DEV_HOST_OK=true`)
- ✅ CORS wildcard `["*"]` убран из `main.py`
- ✅ User-поля: `ai_trial_used`, `subscription_status`, `subscription_expires_at`, `subscription_product_id`, `subscription_original_transaction_id`
- ✅ `POST /auth/apple` — реальная проверка через Apple JWKS (RS256, audience=APPLE_BUNDLE_ID, issuer)
- ✅ `POST /auth/device` **полностью удалён** + `get_current_device` / `require_device` / per-device rate-limit
- ✅ JWT subject теперь `user:{id}`, legacy device-токены отвергаются
- ✅ AI trial gate (`/parse`, `/parse-audio` → 402 при `ai_trial_used >= 50` для не-Premium)
- 🟡 Sync gate: реализован 402-гейт для POST `/sync` (`4549ee6`), но **снят 2026-05-06** в коммите варианта A — sync доступен всем юзерам без подписки. См. шапку файла для аргументации.
- ✅ `/subscription/*`: `status` (реальный), `verify` (DEV-stub на 30 дней), `webhook` (заглушка)
- ✅ In-memory IP-rate-limit на `/auth/apple` (10/мин), `/auth/request-link` (5/мин), `/auth/verify-pin` (10/мин) — закрывает PIN brute-force
- ✅ DEV_STUB-режим в `apple_auth.py` для тестирования без реального SiwA-токена

**iOS (`a23592d`, `673345f`):**
- ✅ Mandatory auth gate в `MonpapaApp.swift` (по `auth.isAuthenticated`); кнопка «Продолжить без входа» удалена
- ✅ `signInWithApple()` через `AuthenticationServices` + `withCheckedThrowingContinuation` + graceful fallback при отсутствии entitlement (`AuthError.appleSignInUnavailable`)
- ✅ `AIService` использует `AuthService.shared.token` (user-JWT); 402 → `AIServiceError.paymentRequired`
- ✅ `SubscriptionService` (refresh status / purchaseStub / trialRemaining / isPremium)
- ✅ `PaywallView` (DEV-stub: «Оформить подписку» дёргает `/subscription/verify` с моком)
- ✅ Trial counter «Осталось X / 50» над input bar в Dashboard, подсветка по уровню остатка
- ✅ Секция «Подписка» в Settings (Premium · до DD.MM.YYYY / Free · X / 50 + кнопка)
- ✅ Авто-paywall при получении 402 от backend
- ✅ +18 локализаций (auth, paywall, subscription)

**Decisions, зафиксированные при реализации:**
- AI trial = **50** запросов lifetime на user
- БД дропается при выкатке (юзеры с нуля), миграция старых не делается
- ~~Sync READ доступен всем; WRITE — только Premium~~ — **пересмотрено 2026-05-06**: sync (push + pull) **доступен всем без подписки**. Premium = безлимитный AI, не sync. Аргументация выше в шапке файла.
- `/auth/device` **удалён полностью** (а не 410 Gone)
- Per-device rate-limit удалён (50 trial выполняет роль квоты)
- Alembic baseline отложен — остаёмся на `Base.metadata.create_all` пока БД droppable

---

---

## Решение

Переходим со схемы **«можно работать без логина + опциональный sync»** на схему **C**:

- **Логин обязателен с первого запуска.** Sign in with Apple — primary, magic-link по email — fallback.
- **AI-функции — trial (N бесплатных запросов на user_id), потом подписка.**
  - Анонимного device-режима для AI больше нет → закрывает фарм device_id.
- **Sync — флаг в настройках (`sync_enabled`), а не отдельный «режим приложения».**
  - Локальная SwiftData всегда есть; sync_enabled=true просто пушит дельту в backend.
- **Подписка** — открывает (а) AI без trial-лимита, (б) sync между устройствами. Оба бенефита в одном SKU.

### Почему не A (текущее)
Бесконечный фарм device_id → AI-квота сливается без затрат для атакующего (см. [`audit/A1_backend_surface.md`](audit/A1_backend_surface.md) 🔴 «фабрика device_id»). Плюс реальный UX-баг: пользователь полгода без логина → логинится → его существующий аккаунт затирает локальные данные при sync.

### Почему не B (полный обязательный логин без trial)
Низкая конверсия: юзер не успевает «пощупать» AI, не понимает за что платить.

---

## Целевая архитектура

### Onboarding flow

```
Запуск → Welcome screen
       ↓
   "Sign in with Apple"   ← primary
       ↓ (или)
   "Войти по email"        ← fallback (Magic Link / PIN)
       ↓
   User создан/найден → JWT в Keychain → главный экран
```

Без авторизации главный экран недоступен. Никаких «попробовать без логина».

### AI trial

- На `User` добавляется `ai_trial_used: int` (или используется уже существующий счётчик в Device, перенесённый на User).
- `AI_TRIAL_LIMIT` — 50 запросов (значение TBD).
- При исчерпании trial и отсутствии активной подписки → 402 Payment Required + paywall на клиенте.
- `Device.ai_requests_today` / `ai_audio_requests_hour` остаются как **rate-limit** (защита от спама в рамках одного юзера), но НЕ как «бесплатная квота для анонима».

### Sync

> **Update 2026-05-06**: устаревшие требования ниже зачёркнуты — sync теперь доступен всем без подписки.

- `UserSettings.sync_enabled` уже есть — оставляем как user preference (юзер может выключить sync вручную).
- ~~`sync_enabled=true` доступно только активной подписке.~~
- ~~Если подписка кончилась → `sync_enabled` остаётся, но push-операции возвращают 402.~~
- POST `/sync` и GET `/sync/changes` оба доступны для любого `require_user`. Локальная SwiftData продолжает работать в любом случае.

### Подписка

- StoreKit 2 (auto-renewable).
- Server-side validation через App Store Server API (отдельный эндпоинт `/api/v1/subscription/verify`).
- Кэшировать receipt в `User.subscription_status` + `User.subscription_expires_at`.
- Webhook `App Store Server Notifications V2` → обновление статуса при cancel/refund.

---

## Изменения в backend

### Схема БД (Alembic-миграция, не `create_all`)

```sql
-- users
ALTER TABLE users ADD COLUMN apple_user_id VARCHAR(255) UNIQUE;  -- уже есть в models.py
ALTER TABLE users ADD COLUMN ai_trial_used INTEGER DEFAULT 0 NOT NULL;
ALTER TABLE users ADD COLUMN subscription_status VARCHAR(20) DEFAULT 'free' NOT NULL;
ALTER TABLE users ADD COLUMN subscription_expires_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN subscription_product_id VARCHAR(100);
ALTER TABLE users ADD COLUMN subscription_original_transaction_id VARCHAR(100);

-- devices: счётчики остаются как rate-limit, но смысл меняется
-- (защита от спама внутри пользователя, а не от анонима)

-- новая таблица для App Store webhook'ов (idempotency)
CREATE TABLE app_store_notifications (
    id BIGSERIAL PRIMARY KEY,
    notification_uuid VARCHAR(64) UNIQUE NOT NULL,
    notification_type VARCHAR(50) NOT NULL,
    user_id INTEGER REFERENCES users(id),
    payload JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### Новые эндпоинты

| Path | Method | Описание |
|------|--------|----------|
| `/api/v1/auth/apple` | POST | Sign in with Apple — принимает identity_token, возвращает JWT |
| `/api/v1/subscription/verify` | POST | Проверить App Store receipt, обновить `subscription_status` |
| `/api/v1/subscription/status` | GET | Текущий статус подписки + остаток AI trial |
| `/api/v1/subscription/webhook` | POST | App Store Server Notifications V2 (signed JWT) |

### Изменения в существующих эндпоинтах

- **Удалить** `/api/v1/auth/device` — анонимный device-режим больше не нужен. (Или оставить, но возвращать 410 Gone, чтобы старые клиенты понимали, что нужно обновиться.)
- `/api/v1/ai/parse`, `/api/v1/ai/parse-audio`:
  - `Depends(require_device)` → `Depends(require_user)` (не just device).
  - Перед вызовом AI: `if user.subscription_status != 'active' and user.ai_trial_used >= AI_TRIAL_LIMIT: raise 402`.
  - После успешного вызова: если не подписчик → `user.ai_trial_used += 1`.
- `/api/v1/sync` (POST):
  - Если `subscription_status != 'active'` → 402 Payment Required.
- `/api/v1/sync/changes` (GET):
  - Те же правила. (Альтернатива: разрешать read даже без подписки, чтобы юзер мог восстановить свои данные при покупке нового устройства, если когда-то платил.)
- DEV_MODE: ужесточить — запускать только если хост = localhost/127.\*.

### Removed code

- `Device.user_id` остаётся (telemetry / per-device rate-limit), но `Device` больше не sole identity.
- `get_current_device` без `user` — мёртвый, удалить.
- `MagicCode.used` — ввести в работу либо удалить (см. A1 🟢 #3).

---

## Изменения в iOS-клиенте (Monpapa/)

> Детали зависят от текущей структуры — проверим в B-блоке аудита.

- **Welcome screen** перед главным окном: SiwA + email. Сейчас, судя по [AuthService] и [KeychainService], логин уже реализован, но опционален.
- **Гейт перед всеми экранами**: `if !auth.isLoggedIn { showWelcome() }`.
- **Локальная БД (SwiftData)** остаётся, но привязывается к `userId` сразу при создании записей. Без `userId` — записей не существует.
- **Paywall**: новый экран после исчерпания AI trial и при попытке включить sync. StoreKit 2.
- **AI-вызовы**:
  - При 402 → показать paywall.
  - Счётчик «осталось X из 50 trial-запросов» — добавить в UI (например, под полем ввода).
- **Удалить ветки кода для анонимного режима**: `if user == nil { useLocal() } else { useSync() }` — упрощается.

---

## Миграция существующих данных

> Сейчас на проде, по-видимому, уже есть users + devices. Нужно подтвердить через `psql` на VPS перед миграцией.

### Сценарий 1: устройство ИМЕЕТ привязку к user (`devices.user_id IS NOT NULL`)
- При обновлении приложения — токен валиден, юзер просто продолжает работать. Данных в БД у него уже есть. AI trial = 0 (если уже не подписчик — даём ему свежий trial как «спасибо за апгрейд», или ставим `ai_trial_used = AI_TRIAL_LIMIT` чтобы старые юзеры сразу видели paywall — TBD).

### Сценарий 2: устройство БЕЗ привязки (`devices.user_id IS NULL`)
- Старый клиент работал в анонимном режиме. После обновления:
  - Локальная SwiftData сохранена → юзер видит свои данные.
  - Но AI и sync не работают, пока он не залогинится.
  - При первом успешном логине — клиент пушит локальные данные через `/sync` (после оформления подписки).
  - **Проблема**: если пользователь логинится в существующий аккаунт с уже синхронизированными данными → конфликт «локальные vs облачные». Нужен onboarding-флоу «у нас уже есть ваши данные на сервере — вы хотите залить локальные дополнительно или начать заново».
- Альтернатива (проще): при выкатке новой версии **в release notes** написать «обязательная авторизация при следующем входе». Клиент при логине показывает диалог: «Влить локальные данные в аккаунт? Да/Нет/Только новые». Это разовая UX-ситуация.

### Сценарий 3: новый пользователь
- Welcome → SiwA → trial → paywall. Без хитростей.

---

## Этапы миграции (порядок реализации)

> Каждый этап — отдельная сессия с отдельной веткой. Тесты + ручная проверка между этапами.

1. ✅ **Закрыть A1-критики, не зависящие от auth-модели** — `5384e08`
   - ✅ SECRET_KEY fail-fast (`field_validator`)
   - ✅ Раздельный `docker-compose.prod.yml` без `--reload`
   - ⏸️ Alembic baseline — **отложен**, БД droppable, сделать при первом реальном юзере

2. 🟡 **Backend: добавить поля в `User`** — `4549ee6` (без Alembic, через `create_all`)
   - ✅ Поля subscription_*, ai_trial_used добавлены в models.py
   - ⏸️ Alembic-миграции `0001_baseline.py` / `0002_user_subscription_fields.py` — отложены

3. ✅ **Backend: Sign in with Apple** — `4549ee6`
   - ✅ `/api/v1/auth/apple` + JWKS-проверка identity_token (`apple_auth.py`)
   - ✅ DEV_STUB-режим для тестирования (apple_sub привязан к device_id)
   - ⏳ Тесты `pytest test_apple_auth.py` — TODO

4. 🟡 **Backend: подписки (StoreKit server-side)** — `4549ee6`
   - ✅ `/subscription/status` (реальный)
   - 🟡 `/subscription/verify` (DEV-stub: 30 дней active) — нужна реальная проверка через App Store Server API
   - 🟡 `/subscription/webhook` (заглушка) — нужна реальная App Store Server Notifications V2 валидация

5. ✅ **Backend: AI trial-гейт + sync-гейт** — `4549ee6`
   - ✅ `require_user` в `/ai/parse`, `/ai/parse-audio`, `/ai/mapping`
   - ✅ 402 при `ai_trial_used >= 50` для не-Premium
   - ✅ POST `/sync` → 402 без подписки; GET `/sync/changes` доступен всем

6. ✅ **Backend: rate-limit инфраструктура** — `4549ee6`
   - ✅ In-memory sliding-window IP-rate-limit (`rate_limit.py`)
   - ✅ `/auth/apple` 10/мин, `/auth/request-link` 5/мин, `/auth/verify-pin` 10/мин
   - ⏳ TODO для multi-instance — заменить на Redis-counter

7. ✅ **Backend: удалить `/auth/device`** — `4549ee6`
   - ✅ Полностью удалён + `get_current_device` / `require_device` / per-device rate-limit

8. ✅ **iOS: Welcome screen + SiwA wiring** — `a23592d`
   - ✅ Gate в `MonpapaApp.swift` по `auth.isAuthenticated`
   - ✅ `signInWithApple()` + graceful fallback `appleSignInUnavailable`
   - ⏳ TODO: `Monpapa.entitlements` + регистрация Bundle ID при наличии Apple Developer Program

9. 🟡 **iOS: paywall + StoreKit 2** — `673345f`
   - ✅ `SubscriptionService` + `PaywallView` + AI trial counter + Settings секция
   - 🟡 Реальный StoreKit 2 (`Product.products` / `.purchase()` / `Transaction.verify()`) — заглушка

10. ⏸️ **iOS: миграция локальных данных** — **скип**
    - Зафиксировано: БД дропается, юзеры создаются с нуля → миграцию не делаем

11. ⏳ **App Store Review submission** — TODO
    - Требует Apple Developer Program ($99) + реальный SiwA + StoreKit
    - `/auth/account` DELETE уже есть — Apple Guidelines 5.1.1(v) выполнен

---

## Открытые вопросы

### Решённые при реализации (2026-05-05)

- ✅ **Размер AI trial: 50 запросов** — закрепили в `Settings.AI_TRIAL_LIMIT`.
- ✅ **«Приземление» trial при апгрейде:** не актуально, БД дропается.
- ✅ **Sync без подписки:** доступен полностью (push + pull). POST `/sync` → 200, GET `/sync/changes` → 200. Update 2026-05-06: переход с «WRITE Premium» на полностью бесплатный sync.

### Остались для будущих сессий

- **Структура подписки:** monthly / yearly / lifetime? Цена в App Store Connect. Сейчас в коде хардкод «299 ₽/мес».
- **Apple Sign in revocation webhook**: пользователь может отозвать SiwA из настроек Apple ID — Apple шлёт нотификацию. Обрабатывать? Сейчас не реализовано.
- **Web-версия для onboarding ссылок** — Magic Link открывается в браузере, но `/auth/verify` отвечает JSON-ом. Нужна HTML-страница с deeplink в приложение.
- **Refresh-token + revocation list** — текущие 30-дневные JWT остаются.

---

## Связь с production-readiness аудитом

После реализации pragmatic-итерации (2026-05-05) актуальный статус критов A1:

| Критик A1 | Статус после реализации |
|-----------|-------------------------|
| 🔴 SECRET_KEY дефолт | ✅ **закрыт** — fail-fast `field_validator` (`config.py`) |
| 🔴 `/auth/device` фабрика квот | ✅ **закрыт** — эндпоинт удалён, токенов на анонимный device больше не выдаётся |
| 🔴 DEV_MODE auto-login | 🟡 **ужесточён** — `@model_validator` запрещает не-localhost без явного `DEV_HOST_OK=true` + WARNING-логи. DEV_MODE всё ещё может выдать dev-юзера, но только на dev-машине. |
| 🔴 PIN brute-force на `/verify-pin` | 🟡 **частично** — IP-rate-limit 10/мин (`rate_limit.py`). Под одну подсеть всё ещё уязвимо при долгом окне атаки. |
| 🔴 IDOR через `category_id` / `counterpart_id` в CRUD | ❌ **остался** — нужно отдельной сессией добавить mass-assignment защиту в transactions/debts |
| 🔴 `--reload` в production-контейнере | ✅ **закрыт** — `docker-compose.prod.yml` без `--reload`/bind-mount, `--workers 2`, healthcheck |
| 🟡 CORS wildcard `["*"]` + `allow_credentials=True` | ✅ **закрыт** — wildcard убран в `main.py` |
| 🟡 Dev-скрипты в production-образе | ✅ **закрыт** — `.dockerignore` исключает `check_cache.py`, `test_db_*.py`, `*.db`, `*.log` |
| 🟡 Host-header injection в magic-link | ❌ **остался** — `request.headers.get("host")` всё ещё доверяется без allow-list |
| 🟡 PII в логах (raw_text транзакций, full prompt) | ❌ **остался** — `ai.py` всё ещё логирует SYSTEM+USER prompt на INFO |
| 🟡 `/docs`, `/redoc` открыты в проде | ❌ **остался** — нужно гейтить за `DEV_MODE` или auth |
| 🟡 `x-forwarded-proto` без `forwarded_allow_ips` | 🟡 **частично** — prod-compose использует `--proxy-headers`, но `forwarded_allow_ips` не задан |
| 🟢 Нет healthcheck для backend | ✅ **закрыт** в prod-compose (curl /health) |

**Итог:** 6 из 13 критов/medium закрыты, 2 ужесточены, 5 остались — это отдельная сессия (можно назвать «**A1-fixups**» или включить в **A2-аудит**). Начать стоит с **IDOR** — он самый опасный из оставшихся.
