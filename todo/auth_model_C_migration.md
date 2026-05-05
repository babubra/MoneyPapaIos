# Auth Model C — миграция на обязательную авторизацию

> Решение принято: 2026-05-04 (диалог с Opus 4.7)
> Статус: 📝 Planning — код не трогаем, пока не закончен аудит и не закрыты A1-крит.

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

- `UserSettings.sync_enabled` уже есть — оставляем.
- `sync_enabled=true` доступно только активной подписке.
- Если подписка кончилась → `sync_enabled` остаётся, но push-операции возвращают 402; локальная БД продолжает работать.

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

1. **Закрыть A1-критики, не зависящие от auth-модели** *(до миграции)*
   - Ротация `SECRET_KEY`, секрет-менеджер.
   - Раздельный `docker-compose.prod.yml` без `--reload`.
   - Alembic baseline + миграции.
   - Это не блокируется решением C — нужно сделать в любом случае.

2. **Backend: Alembic baseline + добавить поля в `User`**
   - Миграция `0001_baseline_schema.py` (snapshot текущих моделей).
   - Миграция `0002_user_subscription_fields.py`.

3. **Backend: Sign in with Apple**
   - Эндпоинт `/api/v1/auth/apple` + проверка identity_token (JWKS Apple).
   - Тесты: stub identity_token валидным/невалидным.

4. **Backend: подписки (StoreKit server-side)**
   - `/subscription/verify`, `/subscription/status`, webhook.
   - Тестовый sandbox-аккаунт App Store.

5. **Backend: AI trial-гейт + sync-гейт**
   - `require_user` вместо `require_device` в `/ai/*`.
   - Проверка trial / subscription_status.
   - 402 ответы.

6. **Backend: rate-limit инфраструктура**
   - SlowAPI (или Redis-counter) для `/auth/*`.
   - IP-rate-limit на `/auth/apple`, `/auth/request-link`, `/auth/verify-pin`.

7. **Backend: deprecate `/auth/device`**
   - Возвращать 410 Gone (или удалить).

8. **iOS: Welcome screen + SiwA**
   - Гейт перед главным экраном.

9. **iOS: paywall + StoreKit 2**

10. **iOS: миграция локальных данных**
    - При первом логине после апдейта — диалог «у нас на сервере есть данные, что делать?».

11. **App Store Review submission**
    - Apple обязательно проверяет SiwA + delete account (последнее уже есть — `/auth/account` DELETE).

---

## Открытые вопросы (нужно решить до старта)

- **Размер AI trial:** 30 / 50 / 100 запросов? Подсмотреть у конкурентов (Cleo, Copilot Money).
- **Структура подписки:** monthly / yearly / lifetime? Цена.
- **«Приземление» trial при апгрейде:** старым юзерам полный trial, или сразу paywall, или 50% trial?
- **Sync read без подписки** разрешать или нет (восстановление при ре-инсталле).
- **Apple Sign in revocation webhook**: пользователь может отозвать SiwA из настроек Apple ID — Apple шлёт нотификацию. Обрабатывать?
- **Web-версия для onboarding ссылок** — нужна, потому что Magic Link открывается в браузере. Сейчас `/auth/verify` отвечает JSON-ом, что не годится для web-юзера. Заменить на HTML-страницу с deeplink в приложение.

---

## Связь с production-readiness аудитом

Решение C **не отменяет** аудит — большинство findings из A1 валидны при любой архитектуре. Но **3 критика из A1 закрываются автоматически** при переходе на C:

| Критик A1 | Закрывается переходом на C? |
|-----------|------------------------------|
| 🔴 SECRET_KEY дефолт | ❌ нет, нужно фиксить отдельно |
| 🔴 `/auth/device` фабрика квот | ✅ да — эндпоинт удаляется |
| 🔴 DEV_MODE auto-login | 🟡 частично — DEV_MODE остаётся, но без анонимного device |
| 🔴 PIN brute-force | ❌ нет, magic-link/PIN остаётся как fallback |
| 🔴 IDOR через category_id | ❌ нет, нужно фиксить отдельно |
| 🔴 `--reload` в проде | ❌ нет, нужно фиксить отдельно |

→ После C-миграции аудит A1 нужно **частично переснять** (проверить, что новые эндпоинты не добавили новых дыр), но фундаментальные проблемы остаются.
