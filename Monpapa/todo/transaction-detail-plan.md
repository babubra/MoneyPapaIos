# TransactionDetailView — План реализации

> **⚠️ ПРАВИЛА РАБОТЫ С ЭТИМ ПЛАНОМ:**
> 1. Выполнять задачи **маленькими порциями** — по одному шагу за раз
> 2. **Согласовывать** начало каждого следующего шага с пользователем
> 3. После выполнения каждого пункта — **отметить** его как выполненный `[x]`
> 4. Не переходить к следующему шагу без подтверждения пользователя

---

## Контекст

**Цель:** Экран просмотра и редактирования транзакции по тапу из списка на Dashboard.

**Архитектурное решение:** Отдельная view `TransactionDetailView`, НЕ переиспользуем `AddTransactionSheet` (слишком перегружена AI-логикой).

**Данные из `TransactionModel`:**
| Поле | Тип | Описание |
|---|---|---|
| `type` | income/expense | Тип |
| `amount` | Decimal | Сумма |
| `currency` | String | Валюта |
| `transactionDate` | Date | Дата операции |
| `comment` | String? | Комментарий |
| `rawText` | String? | Оригинальный текст от AI |
| `category` | CategoryModel? | Категория (связь) |
| `createdAt` | Date | Дата создания записи |
| `attachmentPath` | String? | Фото чека (будущее) |

---

## Шаг 1: Read-only экран `TransactionDetailView`

Отдельный файл `Views/TransactionDetailView.swift`.

**UX:** Открывается по тапу на `TransactionRow` в Dashboard. Sheet (`.sheet`) снизу вверх, как и `AddTransactionSheet`.

**Структура экрана (read-only):**
```
┌─────────────────────────────────┐
│  ←  Детали операции    [Edit]   │ ← toolbar
│                                 │
│        -1 520 ₽                 │ ← крупная сумма с цветом (coral/green)
│        Расход                   │ ← тип мелким текстом
│                                 │
│  ┌─────────────────────────────┐│
│  │ 📅  Дата       3 апр 2026  ││
│  │─────────────────────────────││
│  │ 🍕  Категория  Продукты    ││ ← иконка + name (+ parent)
│  │─────────────────────────────││
│  │ 💬  Комментарий            ││
│  │     Обед в кафе             ││ ← если есть
│  └─────────────────────────────┘│
│                                 │
│  ▶ Распознанный текст AI        │ ← DisclosureGroup (свёрнут)
│    «потратил 500 на обед»       │ ← раскрытый (серый мелкий текст)
│                                 │
│  [ 🗑  Удалить транзакцию ]     │ ← красная кнопка (soft delete)
│                                 │
└─────────────────────────────────┘
```

**Правила для rawText:**
- Показывать `DisclosureGroup` **только если `rawText` есть И отличается от `comment`**
- Если пользователь не менял комментарий (rawText == comment) → не дублировать
- По умолчанию **свёрнут** — раскрывается по тапу

- [x] Создать `TransactionDetailView.swift` (read-only карточка)
- [x] Стиль: дизайн-токены `MPColors`, `MPTypography`, `MPSpacing`, `MPCornerRadius`
- [x] Крупная сумма по центру (как в AddTransactionSheet) с цветом типа
- [x] Карточка с деталями: дата, категория (с иконкой + parent path), комментарий, rawText
- [x] Кнопка «Удалить» (soft delete + триггер `.dataDidChange`)
- [x] Confirm alert перед удалением

**Проверка:** Тап → sheet открывается → данные корректны → удаление работает

---

## Шаг 2: Навигация — тап по `TransactionRow` → `TransactionDetailView`

- [x] В `DashboardView.recentTransactionsSection` — обернуть `TransactionRow` в `Button` → привязать `.sheet`
- [x] Состояние: `@State private var selectedTransaction: TransactionModel?`
- [x] Sheet: `.sheet(item: $selectedTransaction) { TransactionDetailView(transaction: $0) }`

**Проверка:** Тап на строку → sheet с деталями

---

## Шаг 3: Inline-редактирование

- [x] Кнопка «Редактировать» в toolbar (карандаш)
- [x] `@State private var isEditing = false`
- [x] В режиме edit:
  - Сумма → TextField с `.decimalPad`
  - Дата → DatePicker
  - Категория → тап → sheet с `CategoryPickerView`
  - Комментарий → TextEditor
  - Тип → сегмент (расход/доход)
- [x] Кнопки: «Сохранить» (apply + `.dataDidChange`) и «Отмена» (discard)
- [x] При сохранении: обновить `updatedAt`, триггер sync

**Проверка:** Edit → изменить сумму/категорию → сохранить → данные обновлены

---

## Шаг 4: Полировка

- [x] Анимация перехода read ↔ edit (`withAnimation`)
- [x] Пустые состояния: нет категории → «Без категории», нет комментария → скрыть секцию
- [x] Формат суммы: разделитель тысяч пробелом (как в `TransactionRow`)
- [x] Формат валюты: символ (₽/$/€) вместо кода
- [x] Previews: тёмная/светлая тема, доход/расход, с/без категории

---

## Примечания

- `TransactionModel` передаётся как `@Bindable` (SwiftData) → изменения автосохраняются
- Soft delete: `transaction.deletedAt = Date()` + `transaction.updatedAt = Date()`
- Триггер синхронизации: `NotificationCenter.default.post(name: .dataDidChange, object: nil)`
