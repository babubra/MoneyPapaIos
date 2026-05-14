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

#### Известные issues для B-блока (зафиксировано до сессии аудита)

**1. Дата transactions/debts сдвигается на -1 день при КАЖДОМ sync round-trip (накопительный timezone-bug) — ✅ FIXED 2026-05-14 (Opus 4.7, сессия `c-generic-wilkes`)**

- **Fix:** добавлено `formatter.timeZone = TimeZone(identifier: "UTC")` к 4 date-only `DateFormatter`-инстансам:
  - [`Monpapa/Monpapa/Services/SyncService.swift:102`](../Monpapa/Monpapa/Services/SyncService.swift) (`makeFlexibleDecoder`, парсер Pull-ответа)
  - [`Monpapa/Monpapa/Views/AddTransactionSheet.swift:512`](../Monpapa/Monpapa/Views/AddTransactionSheet.swift) (AI-prefill `result.date`)
  - [`Monpapa/Monpapa/Views/AddDebtSheet.swift:466`](../Monpapa/Monpapa/Views/AddDebtSheet.swift) (AI-prefill `result.date` → `debtDate`)
  - [`Monpapa/Monpapa/Views/AddDebtSheet.swift:476`](../Monpapa/Monpapa/Views/AddDebtSheet.swift) (AI-prefill `result.dueDate` → `dueDate`)
- **Encode-side не трогали:** `ISO8601DateFormatter().string(from:).prefix(10)` в `SyncService.swift:341/360/361/377` уже использует UTC по умолчанию. После fix'а парсера `Date` корректно представляет UTC-midnight → round-trip stable.
- **Backfill не делался** (договорённость). Просевшие записи остались на `-1`, но больше не уезжают.
- **Verified (e2e в симуляторе, iPhone 17, 2026-05-14):** введены 6 новых транзакций через AI после fix'а, прогнаны 2 sync round-trip над существующими 11 записями. Снапшоты БД:
  - До fix'а (id 1–11, created 2026-05-13): `transaction_date=2026-05-12` — застыло, после 2 round-trip **не уехало** на `2026-05-10`.
  - После fix'а, без явной даты («купил кофе 200»): `transaction_date=2026-05-14` (today). До fix'а было бы `-1`.
  - После fix'а, с явной датой («получил зарплату 5000 13 мая»): `transaction_date=2026-05-13` — AI отдал `2026-05-13`, iOS правильно распарсил. До fix'а было бы `2026-05-12`.
- **Что НЕ покрыли:** unit-тест round-trip stability (нет XCTest-target в `Monpapa/`); DatePicker manual edit case (теоретическая off-by-one на полночь — в реальности не воспроизводится, т.к. SwiftUI `DatePicker(.date)` сохраняет time-component исходного `Date()=now`); backfill-миграция для просевших записей.

**Оригинальный bug-report (для истории):** (2026-05-13, сессия `flickering-prancing-prism`, ручной тест в симуляторе)
- **Где:** [`Monpapa/Monpapa/Services/SyncService.swift`](../Monpapa/Monpapa/Services/SyncService.swift) — парсинг date-only полей (`transaction_date`, `debt_date`) из Pull-ответа без явного `TimeZone.gmt`. Также проверить [`Monpapa/Monpapa/Models/TransactionModel.swift`](../Monpapa/Monpapa/Models/TransactionModel.swift) и `DebtModel.swift` на наличие `Date` ↔ string converters.
- **Что:** AI возвращает `"date":"2026-05-13"`, iOS-UI **отображает правильно** «13 мая 2026 г.» (подтверждено скриншотом сессии: AddTransactionSheet корректно показывает дату). Но при первом sync на бэке оказывается `transaction_date=2026-05-12` (-1). И — **критичный нюанс** — **при каждом следующем sync эта дата сдвигается ещё на -1**:

  | Действие | `debt_date` в `debts` БД |
  |---|---|
  | Создан (`дал Васе 5000`, AI date=2026-05-13) | **2026-05-12** (-1) |
  | После 1-го платежа (Pull→Push round-trip) | **2026-05-11** (-1 ещё) |
  | После 2-го платежа (Pull→Push round-trip) | **2026-05-10** (-1 ещё) |

  То есть проблема **не только в первичной записи**, но в **Pull→Decode→Re-Push цикле для существующих**. Каждый sync ест ещё день. Новые записи (`debt_payments.payment_date=2026-05-13`) сохраняются корректно — баг **только** при апдейте существующих, попавших обратно через Pull.
- **Воспроизведение:** ввести транзакцию → сохранить → проверить `transaction_date` через `psql` → ввести ещё одну транзакцию (триггер общего sync) → проверить дату первой снова. Сместится.
- **Гипотеза:** Pull-response `"transaction_date":"2026-05-12"` парсится в Swift через `DateFormatter` с `dateFormat="yyyy-MM-dd"` без `timeZone = .gmt`. Получается `Date(2026-05-12 00:00 local)` = `Date(2026-05-11 21:00 UTC)` при UTC+3. SwiftData хранит как `Date`. При следующем Push сериализация даёт `"2026-05-11"`. Цикл повторяется.
- **Магнитуда:** **критическая.** При активном использовании (несколько транзакций в день → sync после каждой → все старые получают round-trip) дата старых записей **уезжает в прошлое на 1 день за каждый sync**. За месяц активного использования = месяц назад. **Catastrophic для bookkeeping-приложения.**
- **Hot-fix план для B-сессии (приоритет — наивысший):**
  1. Найти все `DateFormatter` инстансы в `Monpapa/Monpapa/Services/SyncService.swift` (+ моделях). Где `dateFormat == "yyyy-MM-dd"` (date-only) — добавить `formatter.timeZone = TimeZone(identifier: "UTC")`.
  2. Альтернатива: `Calendar(identifier: .gregorian)` с UTC + `dateComponents([.year, .month, .day], from: date)` для всех date-only round-trip'ов.
  3. Unit-тест: encode `Date(2026-05-13 12:00 local)` → строка `"2026-05-13"` → decode обратно → encode → должна остаться `"2026-05-13"` (round-trip stable).
  4. **Backfill:** у существующих юзеров transactions/debts могут быть с просевшими датами. Миграция может вычислить сдвиг (`(created_at::date) - transaction_date` если > 0 → добавить обратно). Альтернатива: оставить как есть, юзер исправит вручную через UI.
  5. ⚠️ Будет risk regression: если юзер вручную выбрал дату в прошлом, fix не должен сдвигать его выбор на +1. Тестировать на real-world сценариях.
- **Связь с UI:** на скриншоте AddTransactionSheet дата **показывается корректно** «13 мая 2026 г.» до сохранения. После сохранения в SwiftData и sync UI **по-прежнему может показывать правильно** (read из SwiftData), но в БД уже -1. Это объясняет почему баг **скрытный** — разработчик, который смотрит только UI, его не увидит.
- **Не AI-баг.** AI отдаёт правильную дату везде.

**2. iOS-клиент не передаёт `counterparts` в `/parse` при дебт-сценариях** (2026-05-13, та же сессия)
- **Где:** [`Monpapa/Monpapa/Services/AIService.swift:97-156`](../Monpapa/Monpapa/Services/AIService.swift) (`parseText`) — `counterparts: [AICounterpartDTO] = []` default. В call-site (вероятно `DashboardView` или `AIInputBar`) `counterparts` не заполняется при отправке.
- **Что:** реальный кейс. Юзер создал контрагента «Вася» (через первое «дал Васе 5000»). Потом ввёл «вернул долг Васе 2000». В iOS-логе: `counterparts(0):` — пустой список. AI отвечает `counterpart_name="Вася", counterpart_is_new=true` (с точки зрения AI — он Васю «не знает»). iOS компенсирует через локальный fuzzy-match (`handleDebtPayment: cp="Вася" ... activeDebts=1`) и находит долг локально. Результат корректен, но это **рабочий workaround вместо нормальной интеграции**.
- **Проблема:** (а) AI получает неполный контекст и не может корректно работать с counterpart_id; (б) при многословных контрагентах («Сергей Иванов» vs «Серёжа Иванов») iOS fuzzy-match может промахнуться, тогда как AI по разделу 7 SYSTEM_PROMPT с явным списком был бы более устойчив; (в) каждый запрос создаёт ложную «новизну» — counterpart_is_new=true для уже существующего юзеру — что может путать iOS-логику в edge-cases.
- **Что предлагается:** в call-site `parseText` передавать `Counterpart.all` (или active, до cap=200 по аналогии с #7 audit'а) — текущий список из SwiftData. Аналогично с `parseAudio`.
- **Магнитуда:** низкая на сейчас (iOS-fallback работает), но **средняя** при росте usage (юзеры с много контрагентами).

**3. iOS payment_flow filter может дать ошибочный платёж — fallback "оставляем все"** (2026-05-13)
- **Где:** [`Monpapa/Monpapa/Views/DashboardView.swift`](../Monpapa/Monpapa/Views/DashboardView.swift) или соседний — `handleDebtPayment` → `фильтр по flow=X (dir=Y)` логика.
- **Что:** реальный кейс. У юзера есть долг с Васей `direction="gave"` (он ДАЛ Васе). Юзер ввёл «вернул долг Васе 2000» (грамматически = «я возвращаю долг Васе» = у меня долг перед Васей). AI правильно по семантике вернул `payment_flow="outbound"` (я отдаю деньги). iOS-логика: `фильтр по flow=outbound (dir=took): 1 → 0` — отфильтровала всё (нет долгов где Вася дал юзеру), потом `⚠️ фильтр пуст — оставляем все 1 долгов (лучше чем ничего)` → применила платёж к **противоположному** долгу.
- **Проблема:** юзер сказал «я вернул» (=я должен), но по факту у него ситуация «Вася должен», и iOS вместо отказа применил платёж к долгу противоположной направленности. paid_amount=2000 на debt direction="gave" — это **уменьшает то, что Вася должен юзеру**, хотя юзер хотел уменьшить **свой** долг (которого не существует).
- **В этом тесте обошлось** — юзер просто оплатил часть долга Васи перед собой как будто Вася сам вернул. Но это **семантически неверно** — фразы «вернул долг Васе» и «Вася вернул долг мне» имеют разный смысл.
- **Что предлагается:** при `flow=X` если нет долгов с правильным direction → не fallback'иться на противоположные, а спросить юзера или открыть AddDebtSheet (это новый долг противоположной направленности? или ошибка ввода?). UX-вопрос для B-сессии.
- **Магнитуда:** средняя — конкретный case часто встречается у юзеров с малым числом долгов где грамматическая фраза неоднозначна.

**4. UI date-форматирование не идёт через `LocalizationManager` — 9 мест с тремя разными подходами, англоязычный юзер видит русские даты — 🟡 MEDIUM** (2026-05-14, сессия `c-generic-wilkes`)
- **Где:** [`Monpapa/Monpapa/Services/LocalizationManager.swift:39-47`](../Monpapa/Monpapa/Services/LocalizationManager.swift) — canonical API `effectiveLocale()` возвращает `ru_RU`/`en_US`/`Locale.current` в зависимости от выбора юзера (`UserDefaults` ключ `appLanguage`: `"ru"`/`"en"`/`"system"`). Приложение поддерживает 2 языка интерфейса.
- **Что:** в 9 UI-точках форматирования дат `LocalizationManager.effectiveLocale()` **не используется ни разу**. Вместо этого три несогласованных подхода:
  - **Хардкод `Locale(identifier: "ru_RU")`** (3 места) — игнорирует выбор юзера полностью:
    - [`Components/BalanceCardView.swift:20`](../Monpapa/Monpapa/Components/BalanceCardView.swift) — день недели на главном (`EEEE` → «Понедельник»)
    - [`Components/BalanceCardView.swift:27`](../Monpapa/Monpapa/Components/BalanceCardView.swift) — день+месяц на главном (`d MMMM` → «14 мая»)
    - [`Views/DebtPickerSheet.swift:161`](../Monpapa/Monpapa/Views/DebtPickerSheet.swift) — даты долгов при выборе платежа
  - **`Locale.current`** (5 мест) — частично корректно: после рестарта iOS подхватывает `UserDefaults.AppleLanguages`, который `LocalizationManager.apply()` выставляет, и `Locale.current` начинает возвращать выбранную локаль. Но: (а) до рестарта не работает; (б) для choice `system` всё равно идёт через системную локаль, а не через что-то, что юзер контролирует в settings приложения:
    - [`Components/TransactionRow.swift:99`](../Monpapa/Monpapa/Components/TransactionRow.swift)
    - [`Components/DebtCard.swift:189`](../Monpapa/Monpapa/Components/DebtCard.swift)
    - [`Views/TransactionListView.swift:370`](../Monpapa/Monpapa/Views/TransactionListView.swift)
    - [`Views/DebtDetailView.swift:407`](../Monpapa/Monpapa/Views/DebtDetailView.swift) (`debt_date`)
    - [`Views/DebtDetailView.swift:414`](../Monpapa/Monpapa/Views/DebtDetailView.swift) (`payment_date`)
  - **Без явной `.locale`** (1 место) — эффективно `Locale.current`, та же история:
    - [`Views/Stats/StatsView.swift:429`](../Monpapa/Monpapa/Views/Stats/StatsView.swift)
- **Симптом:** англоязычный юзер на iOS-симуляторе в РФ-локали системы, выбравший в settings приложения «English» (`AppleLanguages=["en"]` ещё **до рестарта** или впервые после установки) увидит:
  - Главный экран `BalanceCardView`: «Понедельник, 14 мая» вместо «Monday, May 14» — даже после рестарта (потому что хардкод `ru_RU`).
  - `TransactionRow` / `DebtCard` / `TransactionListView` / `DebtDetailView`: после рестарта приложения покажет даты на английском (`Locale.current` подхватит), но до рестарта — на русском.
  - `Stats` view: то же что выше (зависит от рестарта).
- **Магнитуда:** для русских юзеров (предположительно большинство аудитории) всё работает корректно — это «нулевой риск». Для англоязычных — base-line грамотности приложения (финансовый трекер обязан показывать даты в локали юзера). При выходе на не-русские рынки эта проблема станет видна сразу.
- **Что предлагается в B4-сессии (UX consistency):**
  - (а) **Унификация:** заменить все 9 мест на `LocalizationManager.effectiveLocale()`. Это единый canonical источник локали для приложения.
  - (б) **Refactor:** вынести в [`Monpapa/Monpapa/Utils/DateUtils.swift`](../Monpapa/Monpapa/Utils/) (создать) helper'ы:
    - `DateFormatter.appLocalized(format: String) -> DateFormatter` — статическая фабрика с `locale = LocalizationManager.effectiveLocale()`
    - Или кэшируемые форматтеры по template'у (через `setLocalizedDateFormatFromTemplate`).
    Заменить ad-hoc-инстансы во всех 9 местах.
  - (в) **Регрессионный QA:** прогнать смены языка через settings → BalanceCardView, TransactionRow, DebtCard, DebtPicker, DebtDetail, TransactionList, Stats — на ru/en, до и после рестарта.
- **Связь с timezone-фиксом (2026-05-14):** **не связано напрямую**. Timezone-фикс ставит `en_US_POSIX` + UTC на 4 **парсера** в `SyncService`/`AddTransactionSheet`/`AddDebtSheet` — это служебная конвенция парсинга JSON, не UI. UI-форматтеры (эти 9 мест) — отдельный слой, ни одного из них timezone-фикс не задевает. Финдинг открыт во время обзора этих 4 парсеров — попутно увидели несогласованность UI-локали.
- **Tradeoffs для B4-сессии:** (а) `LocalizationManager` сейчас enum со static API — для SwiftUI `@StateObject` / `@EnvironmentObject` это не подходит, форматтеры будут вычисляться при создании View и не обновятся при смене локали без рестарта. После refactor может потребоваться превратить его в `ObservableObject`. (б) Кэшированные `static let formatter` в `BalanceCardView` нужно будет инвалидировать при смене языка — иначе старые форматтеры с прежней локалью переживут смену.

---

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

**4. `message` в `status=rejected`/`incomplete` приходит на английском, нарушая `locale`** (2026-05-13, та же сессия)
- **Где:** [`backend/app/core/system_prompt.py:97-101`](../backend/app/core/system_prompt.py) (раздел 9 «Localization»: «*ALL text fields in response (category_name, ..., message) MUST be in the language specified by `locale` parameter*»).
- **Что:** реальный кейс user_id=1, 2026-05-13, locale=ru. Юзер ввёл «какая погода?». Response модели:
  ```json
  {"status":"rejected","message":"The input does not describe a financial transaction."}
  ```
  `message` на английском, хотя locale=ru. Юзер увидел в UI английскую фразу вместо локализованной.
- **Почему так происходит:** на rejected/incomplete-ответах модель не задействует "общий" перевод (как для category_name), а использует свой template из training data — английская формулировка. Возможно работающий механизм localization для category_name не покрывает message-поле.
- **Что предлагается в C3:** (а) в SYSTEM_PROMPT раздел 9 добавить explicit пример: «*locale=ru → message="Это не похоже на финансовую транзакцию." (не "The input does not describe...")*»; (б) **iOS-fallback** (компенсация для существующих юзеров до правки промпта): держать на клиенте словарь стандартных rejected/incomplete-сообщений в локализованных файлах (`Localizable.xcstrings` уже есть), при `status in (rejected, incomplete)` показывать **локальное** сообщение, игнорируя `message` от AI. Это надёжнее чем рассчитывать на промт-механизм.
- **Магнитуда:** средняя — UX-полировка, но видимая. У не-RU юзеров (en и т.д.) симметрично — может прийти ru-message при locale=en и т.д.

**3. Semantic preferences match съедает квалификатор в тексте — два разных источника дохода объединяются в одну категорию** (2026-05-13, сессия `flickering-prancing-prism`, ручной тест в симуляторе)
- **Где:** [`backend/app/core/system_prompt.py:36-40`](../backend/app/core/system_prompt.py) (раздел 5 «User Category Preferences (HIGHEST PRIORITY)»: формулировка *«matches loosely/semantically»* перекрывает любую конкретику в тексте).
- **Что:** реальный сценарий user_id=1 (2026-05-13). Юзер последовательно создал две income-категории:
  1. «Зарплата РКК Риэлт» (mapping: `зарплата → Зарплата РКК Риэлт`, weight=1)
  2. «Зарплата в университете» (mapping: `зарплата в университете → Зарплата в университете`, weight=1)
  Потом ввёл «получил зарплату **в школе** 7000» — намеревался создать **третью** категорию (он работает и в школе, и в университете, это два разных места). Модель применила semantic-match `школа ≈ университет` и вернула `category_name="Зарплата в университете", category_is_new=false`. Юзер был вынужден исправить (но это его второй override на 3-й транзакции, что плохой UX).
- **Почему так происходит:** это **второе проявление того же финдинга #1** (кефир-кейс), но через другую дверь. Если #1 — это «явный intent через паттерн `запиши в X`», то #3 — «явный квалификатор контекста (`в X`)». Раздел 5 семантически проглатывает оба.
- **Bookkeeping-контекст:** в финансовом приложении источник дохода — это **разная сущность**. Школа и университет — два работодателя, два потока, две категории. Объединять их через «semantic close enough» = терять информацию, которая нужна юзеру для отчётности. Это противоречит самой идее app.
- **Что предлагается в C3:** в дополнение к правке #1 (intent-патернов) — ослабить раздел 5 формулировкой: «*Preferences match only when there's NO disambiguating qualifier (location/source: "в X", "от Y", "для Z") in the user text. If a unique qualifier is present, treat as a separate category even if base item_phrase matches an existing preference.*»
- **Tradeoffs для C3:** (а) рискуем сломать кейсы где semantic match как раз нужен (например, «купил еды в магазине» при preference «еда → Продукты» — qualifier «в магазине» не должен ломать match); (б) нужна evals-серия с двумя классами кейсов: «qualifier-significant» (школа/универ, дом/работа) vs «qualifier-irrelevant» (в магазине/на рынке для еды). Минимум 5+5 примеров; (в) multi-locale — правило про qualifier нужно сформулировать на английском так, чтобы работало на ru/en/de/etc.
- **Доп. находка из той же сессии:** AI на `«вернули 2000 за товар»` (новая категория) вернул `category_is_new=true, category_name=null, category_icon="📦"`. По разделу 4 после M13: «*If `category_is_new=true`, category_name MUST be a real non-empty string — never null*». Модель проигнорировала. Это **C3-bug #2** — фиксируется отдельным пунктом ниже.

**2. AI возвращает `category_name=null` при `category_is_new=true` — нарушение раздела 4** (2026-05-13, та же сессия)
- **Где:** [`backend/app/core/system_prompt.py:27-28`](../backend/app/core/system_prompt.py) (раздел 4 после M13: «*If `category_is_new=true`, category_name MUST be a real non-empty string — never null, never "null", never empty*»).
- **Что:** реальный кейс user_id=1, 2026-05-13 21:10. Текст «вернули 2000 за товар», существующие категории `[Зарплата РКК Риэлт, Зарплата в университете]` (income). Response модели:
  ```json
  {"category_is_new":true, "category_name":null, "category_icon":"📦", "item_phrase":"товар", ...}
  ```
  Юзеру в iOS-UI пришлось вручную создать категорию «Возвраты за товар». iOS-сторона это обработала (показала диалог создания), но это лишний клик и UX-сбой.
- **Почему так происходит:** правило 4 говорит «MUST», но модель `gemini-2.5-flash-lite` иногда возвращает null. Возможные причины: (а) сам null-промт в schema (раздел 10 после M13) ослабил давление; (б) когда модель не уверена в имени категории, она «честно» возвращает null вместо догадки — это разумно с её точки зрения, но плохо для нашего UX. Текущий safety-net `_normalize_null_strings` (`ai.py:175`) приводит строку `"null"` к настоящему `None`, но **не** заполняет null именем.
- **Что предлагается в C3:** (а) усилить раздел 4 шаблоном fallback'а: «*If you cannot confidently invent a category name but `category_is_new=true`, use a generic broad-name based on item_phrase + transaction type (e.g. for income with item_phrase="товар" → category_name="Прочие доходы"; for expense → "Прочие расходы"). NEVER return null.*»; (б) добавить server-side safety: если `category_is_new=true && category_name in (null, "")` — backend подставляет дефолт по transaction type, логирует WARN. Это **гарантированный fallback** на случай если модель снова накосячит после правки промпта.
- **Eval-кейс:** в golden добавить `m7_new_category_must_have_name` — текст «вернули 2000 за товар» с пустым списком категорий, assert `category_is_new=true AND category_name not in (None, "", "null")`. Сейчас этот кейс прогон бы упал.

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
| **B-bug #1 (timezone)** | ✅ Fixed | 2026-05-14 (Opus 4.7) | 4 date-only `DateFormatter` + UTC TZ в `SyncService`/`AddTransactionSheet`/`AddDebtSheet`. e2e verified в симуляторе, 17 записей стабильны после 2 round-trip. См. раздел «Известные issues для B-блока» → пункт 1 |
| A2 | ⬜ TODO | — | — |
| A3 | ⬜ TODO | — | — |
| A4 | ⬜ TODO | — | — |
| B1 | ⬜ TODO | — | — |
| B2 | ⬜ TODO | — | — |
| B3 | ⬜ TODO | — | — |
| B4 | ⬜ TODO | — | — |
| C1 | ✅ Done | 2026-05-06 (Opus 4.7) | [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) (объединён с C2) |
| C2 | ✅ Done | 2026-05-06 (Opus 4.7) | [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) (объединён с C1) |
| **C1+C2-fixups** | 🔄 In progress | 2026-05-13 (Opus 4.7) | M6 + #4/#5/#7/#16 + **M14** + **M13** + **#3** закрыты. **#1 (prompt-cache)** исследован и **переоткрыт**: aitunnel не делает prefix-cache → требуется смена провайдера, отложено. **#3 (retry+idempotency)** закрыт: backend `IdempotencyStore` + iOS `executeWithRetry` (backoff `[0,1s,3s]`) + `Idempotency-Key` header → AI вызывается 1 раз на user-action, trial не списывается повторно. Дальше: **#15** (Premium cap) → **#10** (audio duration) → **#2** (Device cap) → хвост 🟢. См. [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) |
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
- 2026-05-11 — закрыт **#14 (M14)** в C1+C2-fixups (Opus 4.7, сессия `breezy-wandering-church`): eval-инфраструктура `backend/tests/` (pytest + pytest-asyncio в `requirements-dev.txt`, `tests/` исключён из Docker-образа). Два слоя: (а) mock-based — 31 unit/retry/regression-тест без сети; (б) golden — 15 кейсов через реальный aitunnel `gemini-2.5-flash-lite`, ~$0.03 за прогон, помечены `@pytest.mark.golden`. Главный фокус golden — **долги**: 8 кейсов покрывают debt_take/debt_give/debt_payment + fuzzy-matching counterpart (Серёжа↔Сергей, Mike↔Michael) + payment_flow inbound/outbound + ambiguous-counterparts. **14/15 golden green с первого прогона**. Артефакты сессии для будущих фиксов: (1) **корректировка к #1**: prompt caching у aitunnel **уже работает**, но нестабильно (cached=2980 на 2 запросах из 15, остальные 0) — фикс #1 должен быть про «стабилизацию», не «включение»; (2) **новый finding для C3**: модель не выставляет `status=incomplete` при отсутствии amount («купил хлеб» → status=ok, amount=null) — покрыто xfail `ru_incomplete_amount`; (3) **дополнительный gap раздела 4 промпта**: при `category_name="Продукты"` + `category_is_new=false` модель иногда возвращает `category_id=null`. Подробности: [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) → секция «Статус закрытия».
- 2026-05-12 — закрыт **#13 (M13)** в C1+C2-fixups (Opus 4.7, сессия `m13-prompt-shortening`): сокращение SYSTEM_PROMPT в 4 малых этапах с golden-сьютом-как-страховкой. (A) убраны кричащие маркеры `(CRITICAL)`/`(IMPORTANT)`/`(REQUIRED in response)` в заголовках разделов 4b/6/7/8/9; (B) раздел 10 — три почти одинаковых JSON-объекта сжаты в один base-shape + word-level type-specific notes для income/expense/debt_give/debt_take/debt_payment; (C) раздел 8 — debt-примеры с 12 до 8 (убраны лексические дубликаты «погасил 3000 Сергею», «рассчитался», «вернул Пете весь долг»); правила `## Determining`, `## CRITICAL вернул/отдал=ALWAYS debt_payment`, `## Key rules` сохранены без изменений; (D) раздел 4b — 5 строк с примерами CORRECT/WRONG → 2 строки. Safety-net через `_normalize_null_strings` (ai.py:175) остаётся, M14 кейс `m3_null_string_category_normalized` это покрывает. **Метрики:** `system_prompt.py` 13705→12350 байт (-9.9%); `SYSTEM_PROMPT` text 9657→8488 chars (-12.1%); средний `prompt_tokens` на golden 3143→2710 (-13.8%, при 1000 запросов/день это ~430K input-токенов экономии в сутки). 14/15 golden остаются passed, mock 43/43. **НЕ трогали** разделы 1, 2 (status=incomplete уже недостаточно строгий — это C3, не M13), 4 (gap с category_id — это C3), 5 (preferences), 7 (counterparts fuzzy), 9 (localization).
- 2026-05-13 — закрыт **#3 (retry + идемпотентность)** в C1+C2-fixups (Opus 4.7, продолжение сессии `flickering-prancing-prism`). Двусторонний фикс: **backend** — новый модуль `backend/app/core/idempotency.py` с `IdempotencyStore` (in-memory TTL=60s, asyncio.Lock, состояния NEW/IN_FLIGHT/CACHED), инстансируется в lifespan, инжектится через FastAPI-dependency. Endpoints `/parse` и `/parse-audio` обрабатывают header `Idempotency-Key` (max-len 128, scoped by user_id): cached → возврат закэшированного ответа без AI-call и без двойного `_consume_trial`; in_flight → 409 Conflict; AI-fail → `release_failure` → юзер ретраит. Без header — back-compat. **iOS** — `AIService.swift`: генерация `idempotencyKey = UUID().uuidString` один раз на user-action в `parseText`/`parseAudio`, header выставлен; новый helper `executeWithRetry` с backoff `[0, 1s, 3s]` (3 попытки), ретраит на URLError-сетевых (timeout/networkLost/notConnected/cannotConnect/cannotFindHost/dnsLookupFailed) и HTTP 502/503/504, НЕ ретраит на 4xx и нефлапающих 5xx. **Тесты:** 8 новых unit-тестов на стор (`tests/test_idempotency.py`), mock-сьют 43→51 passed. **Verified curl:** 2 запроса с одним ключом → 1 AI-call, 1 trial-инкремент; 3-й без ключа → новый AI-call (back-compat). Golden не перезапускался (фикс не затрагивает `_call_ai_text`/SYSTEM_PROMPT). Подробный пост-мортем в [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) → секция «Статус закрытия» от 2026-05-13.
- 2026-05-14 — **зафиксирован новый known issue для B-блока (Opus 4.7, сессия `c-generic-wilkes`):** «UI date-форматирование не идёт через `LocalizationManager`» (пункт 4 в подразделе «Известные issues для B-блока»). 9 UI-точек используют три несогласованных подхода (3× хардкод `ru_RU`, 5× `Locale.current`, 1× без явной локали), ни одна — `LocalizationManager.effectiveLocale()`. Англоязычный юзер на главном `BalanceCardView` видит русские даты независимо от выбранного языка приложения. Магнитуда medium — для русской аудитории не виден, для не-русской — базовый UX-грязь. Закрывается в B4-сессии (UX consistency) с попутным refactor'ом в `Utils/DateUtils.swift`. Не связано с одновременным timezone-фиксом — открыто попутно при обзоре всех `DateFormatter`-инстансов.
- 2026-05-14 — закрыт **B-bug #1 (timezone накопительный)** (Opus 4.7, сессия `c-generic-wilkes`): 🔴 единственный prod-blocker устранён. Корень — `DateFormatter(yyyy-MM-dd)` без `timeZone=UTC` парсит date-only строку в локальной TZ, при UTC+3 → `Date(-3h)` → ISO8601-push даёт `-1` день, цикл повторяется при каждом round-trip. **Fix:** добавлено `formatter.timeZone = TimeZone(identifier: "UTC")` к 4 инстансам — `SyncService.swift:102` (главный, парсер Pull), `AddTransactionSheet.swift:512`, `AddDebtSheet.swift:466` (debtDate), `AddDebtSheet.swift:476` (dueDate). Encode-side (`ISO8601DateFormatter` в SyncService) не трогали — он по умолчанию UTC, после fix'а парсера round-trip stable. **Verified e2e в симуляторе iPhone 17:** 6 новых транзакций через AI-flow получили правильные даты (`2026-05-14` today, `2026-05-13` для «13 мая»), 11 существующих доfix-записей с `2026-05-12` пережили 2 sync round-trip и **не уехали** на `2026-05-10` — bleeding остановлен. **Backfill не делался** (договорённость): просевшие записи остаются на `-1`, юзер при желании поправит через UI. **Out of scope:** XCTest infra для unit-теста round-trip (нет target в Monpapa/), DatePicker manual edge (теоретическая off-by-one на полночь — не воспроизводится, SwiftUI `DatePicker(.date)` сохраняет time-component `Date()=now`), refactor в shared `DateOnlyFormatter` utility — задача B1-аудита.
- 2026-05-12 — **#1 (prompt caching)** исследован в C1+C2-fixups (Opus 4.7, сессия `flickering-prancing-prism`) и **переоткрыт**. Расширен `backend/check_cache.py` режимами `--repeat`, `--user-key`, `--vary` для контролируемых cache-экспериментов (~$0.15 на ~40 запросов). **Ключевое открытие:** aitunnel **не делает префиксное кэширование** SYSTEM_PROMPT. С идентичными prompts cache hit rate 60-90% (артефакт повторов), но с варьирующимися user_text — **0/10 hits даже с `user=u0` + `extra_body.prompt_cache_key=u0`**. M14-наблюдение «2/15 hits» теперь интерпретируется как случайное совпадение полного messages-payload, не как partial prefix-cache. Попытка добавить `user=`/`extra_body` в `_call_ai_text` и `_call_ai_audio` дала **0/15 hits на golden** → откат правки (мёртвый код хуже отсутствующего); mock-тест `test_passes_routing_hints` тоже снят. **Сохранено:** расширенный `check_cache.py --vary` как diagnostic-инструмент для будущих экспериментов с любым AI-провайдером. **Магнитуда подтверждена через aitunnel-биллинг:** miss=0.07 руб, hit=0.04 руб (~1.75× разница). **Финдинг #1 переоткрыт** с переформулировкой: не «стабилизация», а «получить prefix-caching как явный механизм» — через aitunnel openai-compat невозможно. Альтернативы: Gemini direct (`cached_content`), Anthropic Claude (`cache_control`), или ждать поддержки в aitunnel. Решение отложено как архитектурное (требует смены провайдера). Дальше по приоритету: #3 → #15 → #10 → хвост 🟢. Подробный пост-мортем в [`audit/C1_C2_ai_layer.md`](audit/C1_C2_ai_layer.md) → секция «Статус закрытия» от 2026-05-12.
