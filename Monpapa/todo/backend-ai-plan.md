# MonPapa — Backend & AI-распознавание транзакций

> Архитектурные решения и план реализации.
> Согласован 2 апреля 2026.
> Обновлён 2 апреля 2026 — смена AI-провайдера на aitunnel.ru.

---

## 📐 Архитектурные решения

### Backend
- **Новый бэкенд с нуля** (FastAPI), AI-логику адаптировали из старого MonPap
- **API-first**: чистый REST JSON API, клиент-агностичный (iOS сейчас, web потом)
- **Версионирование**: `/api/v1/...` с первого дня
- Хостить можно на том же сервере, отдельный порт/домен
- Полный CRUD для всех сущностей (даже если iOS не использует — web будет)

### Auth
- **Анонимный deviceId** (UUID в Keychain) — AI работает сразу без регистрации
- **Sign in with Apple** — основной метод при включении синхронизации
- **Magic Link (email)** — резервный метод, с rate limit (3 письма / 15 мин / email)
- Все методы выдают единый `Bearer token`

### Синхронизация
- **Offline-first**: всё работает локально (SwiftData), синхронизация опциональна
- При включении sync: `POST /api/v1/sync` с `last_sync_at` + локальные изменения
- Модели sync-ready: `id`, `client_id`, `updated_at`, `deleted_at` (soft delete)

### AI-парсинг
- **Backend-proxy**: iOS → Backend → AiTunnel (Gemini) → iOS (ключ не на клиенте)
- **Промт хранится на сервере** (обновление без релиза в App Store)
- **Категории отправляются с клиента** при каждом запросе (offline-first, всегда актуальные)
- Rate limit: 50 AI-запросов/день на deviceId, 5 аудио/час
- **AI-провайдер**: [aitunnel.ru](https://api.aitunnel.ru/v1/) — OpenAI-совместимый API для Gemini
  - Клиент: `openai` Python SDK (AsyncOpenAI)
  - Модель: `gemini-3.1-flash-lite-preview` (настраивается через `.env`)

### Асинхронный стек (concurrent-ready)
Все компоненты полностью асинхронны — сервер выдерживает сотни одновременных запросов:

| Слой | Технология | Почему async |
|---|---|---|
| HTTP-сервер | `uvicorn` + `asyncio` event loop | принимает N запросов параллельно |
| FastAPI эндпоинты | `async def` | не блокируют event loop |
| AI-клиент | `AsyncOpenAI` (singleton в `app.state`) | один httpx-пул на всё приложение |
| БД | `AsyncSession` + `aiosqlite` / asyncpg | неблокирующие запросы к БД |
| Lifespan | `@asynccontextmanager` | корректный старт/стоп всех ресурсов |

**Ключевое решение**: `AsyncOpenAI`-клиент создаётся **один раз** при старте (`lifespan` в `main.py`) и хранится в `app.state.ai_client`. Все запросы получают его через `Depends(get_ai_client)`. Это даёт переиспользование TCP-соединений через httpx-пул вместо создания нового клиента на каждый запрос.

### Защита от злоупотреблений
- **Текст**: лимит 500 символов (счётчик показывается при <50 осталось)
- **Аудио**: VAD (Voice Activity Detection) на клиенте — считаются секунды речи, не тишины
  - Тишина >5 сек → автостоп «Я вас не слышу»
  - Пауза >3 сек после речи → автостоп и отправка
  - Лимит: 30 сек активной речи
- **Rate limiting**: лимиты в `.env`, счётчики в БД (таблица Device)

---

## 🗂️ Структура бэкенда

```
backend/
├── venv/                      # Python virtualenv
├── requirements.txt           # fastapi, uvicorn, sqlalchemy, openai, ...
├── Dockerfile
├── docker-compose.yml
├── .env.example               # шаблон переменных окружения
├── .env                       # реальные ключи (не в git!)
└── app/
    ├── main.py                # FastAPI app + CORS + init DB
    ├── schemas.py             # Pydantic схемы (DeviceAuthRequest, ParseTextRequest...)
    ├── core/
    │   ├── config.py          # Settings из .env (AITUNNEL_API_KEY, лимиты...)
    │   ├── security.py        # JWT create/decode
    │   └── system_prompt.py   # Системный промт + build_ai_prompt()
    ├── db/
    │   ├── models.py          # Device (rate limiting, is_blocked)
    │   └── session.py         # AsyncSession factory
    └── api/v1/
        ├── auth.py            # POST /api/v1/auth/device
        └── ai.py              # POST /api/v1/ai/parse + /parse-audio
```

---

## ✅ Фазы реализации

> 🟢 = **Sonnet** (код по готовому плану, CRUD, копирование логики)
> 🔴 = **Opus** (архитектура, сложная логика, нестандартные решения)

### Фаза 1 — Минимальный AI (MVP)
Цель: оживить AI-ввод транзакций на iOS.

- [x] 🟢 **Backend**: FastAPI scaffold + config + Docker
- [x] 🟢 **Auth/device**: `POST /api/v1/auth/device` — принимает UUID, выдаёт Bearer token
- [x] 🟢 **AI/parse**: `POST /api/v1/ai/parse` — текст + категории → Gemini → JSON
- [x] 🟢 **AI/parse-audio**: `POST /api/v1/ai/parse-audio` — аудио + категории → Gemini → JSON
- [x] 🔴 **Промт**: скопирован из старого проекта, адаптирован под новую архитектуру
- [x] 🟢 **Rate limiting**: 50 запросов/день, 5 аудио/час на deviceId
- [x] 🟢 **AI-провайдер**: переход на aitunnel.ru (AsyncOpenAI, убран google-genai)
- [x] 🟢 **Async стек**: lifespan + singleton AsyncOpenAI в app.state + AsyncSession — всё concurrent-ready
- [x] 🟢 **End-to-end тест**: auth/device → ai/parse → Gemini 200 OK ✅
- [x] 🟢 **iOS: AIService**: HTTP-клиент для вызова `/ai/parse` и `/ai/parse-audio`
- [x] 🟢 **iOS: AiParseResult**: модель ответа от AI
- [x] 🟢 **iOS: AIInputBar → реальный вызов**: заменить TODO-заглушки на вызовы AIService
- [x] 🔴 **iOS: Preview Sheet**: после AI-парсинга → заполненная форма AddTransactionSheet (UX-дизайн + edge cases)
- [x] 🟢 **iOS: AVAudioRecorder**: запись голоса + VAD


### Фаза 2 — Авторизация и синхронизация
Цель: облачная синхронизация данных между устройствами.

#### Backend (готово ✅)
- [x] 🔴 **Auth**: Magic Link (request-link, verify-pin, verify, link-device, me, logout)
- [x] 🔴 **DB models**: sync-ready (id, client_id, updated_at, deleted_at, user_id) — все модели
- [x] 🔴 **Sync endpoint**: `POST /api/v1/sync` (batch LWW) + `GET /sync/changes` (delta)
- [x] 🟢 **CRUD endpoints**: transactions, categories, counterparts, debts, settings

#### iOS — Auth (готово ✅)
- [x] 🟢 **iOS: AuthService** — HTTP-клиент (requestMagicLink, verifyPin, logout, token)
- [x] 🟢 **iOS: SettingsView** — UI для входа по email + переключатель синхронизации (sheet из ⚙️ на Dashboard)
- [ ] 🟢 **iOS: AuthService → Keychain** — перенос хранения токена из UserDefaults в Keychain

#### Backend — фикс (готово ✅)
- [x] 🟢 **SMTP SSL fix**: `validate_certs=False` в `aiosmtplib` — обход проблемы сертификатов Python на macOS

#### iOS — Sync (ожидает auth ⏳)
- [ ] 🔴 **iOS: SyncService**: фоновая синхронизация (offline queue, retry, merge)
- [ ] 🔴 **iOS: Conflict resolution**: стратегия "last write wins" — реализация и тестирование

#### iOS — Прочее
- [ ] 🔴 **Auth**: Sign in with Apple (позже, после Magic Link)
- [ ] 🟢 **iOS: Подсказки AI**: механизм хранения, загрузки и локализации подсказок для `AIInputBar` (`aiHints`)

### Фаза 3 — Web-интерфейс
Цель: доступ к данным через браузер.

- [ ] 🟢 **Web auth**: Magic Link (или Google/Apple OAuth)
- [ ] 🟢 **Web dashboard**: чтение данных через CRUD endpoints
- [ ] 🟢 **Web AI-ввод**: текстовый парсинг через тот же `/ai/parse`
- [ ] 🟢 **Stats endpoints**: расширенная аналитика для web

---

## 🔧 Настройка окружения

```bash
# 1. Создать .env из примера
cp .env.example .env

# 2. Заполнить ключ в .env:
AITUNNEL_API_KEY=your-key-here

# 3. Запустить локально
source venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload

# 4. Документация API
open http://localhost:8001/docs
```

---

## 📎 Ссылки на старый проект (справочник)

| Файл | Что взяли |
|---|---|
| `/Users/fatau/TEST/MonPap/backend/app/core/system_prompt.py` | Промт + build_ai_prompt() ✅ адаптирован |
| `/Users/fatau/TEST/MonPap/backend/app/api/ai.py` | Структура эндпоинтов ✅ адаптирована |
| `/Users/fatau/TEST/MonPap/backend/app/schemas.py` | Pydantic-схемы ✅ адаптированы |
| `/Users/fatau/TEST/MonPap/iosapp/MonPap/Services/AIService.swift` | iOS HTTP-клиент (следующий шаг) |
| `/Users/fatau/TEST/MonPap/iosapp/MonPap/Models/Common.swift` | AiParseResult модель (следующий шаг) |
