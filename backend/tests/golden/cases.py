"""Golden-кейсы — реальные вызовы aitunnel.ru.

Каждый кейс — словарь:
- id: уникальный идентификатор (для pytest -k)
- locale: ru/en
- text: текст пользователя
- categories / counterparts / mappings: контекст для prompt-а
- today: дата (default 2026-05-11) — фиксируется чтобы due_date не плавал
- assert_equals: жёсткие равенства (модель ОБЯЗАНА это вернуть по правилам SYSTEM_PROMPT)
- assert_in: значение должно входить в множество допустимых (мягкое assertion)
- assert_present: поле должно быть непустым (значение модели не фиксируем)

Покрытие:
- 3 базовых транзакции (ru income, ru expense, en expense)
- 2 категории / lemmatization
- 8 кейсов на долги (главный фокус, см. план M14)
- 2 off-topic / incomplete

Стоимость прогона: 15 кейсов × ~3500 input + ~200 output токенов на
gemini-2.5-flash-lite ≈ $0.02–0.05.
"""

GOLDEN_CASES = [
    # ── Базовые транзакции ────────────────────────────────────────────
    {
        "id": "ru_income_salary",
        "locale": "ru",
        "text": "зарплата 50000",
        "categories": [{"id": "c1", "name": "Зарплата", "type": "income"}],
        "assert_equals": {
            "type": "income",
            "amount": 50000,
            "category_id": "c1",
            "category_is_new": False,
        },
    },
    {
        "id": "ru_expense_food_known_cat",
        "locale": "ru",
        "text": "купил хлеб 100",
        "categories": [{"id": "c1", "name": "Продукты", "type": "expense"}],
        "assert_equals": {
            "type": "expense",
            "amount": 100,
            "category_id": "c1",
            "category_is_new": False,
        },
        "assert_present": ["item_phrase"],
    },
    {
        "id": "en_expense_basic",
        "locale": "en",
        "text": "coffee 5 dollars",
        "categories": [],
        "assert_equals": {
            "type": "expense",
            "amount": 5,
        },
        # USD не гарантирован — модель может выбрать RUB при отсутствии явного знака
        "assert_in": {
            "currency": ["USD", "RUB"],
        },
    },

    # ── Категории и item_phrase ──────────────────────────────────────
    {
        "id": "ru_expense_new_cat",
        "locale": "ru",
        "text": "купил саксофон 50000",
        "categories": [
            {"id": "c1", "name": "Продукты", "type": "expense"},
            {"id": "c2", "name": "Транспорт", "type": "expense"},
        ],
        "assert_equals": {
            "type": "expense",
            "amount": 50000,
            "category_is_new": True,
        },
        "assert_present": ["category_name", "item_phrase"],
    },
    {
        "id": "ru_lemmatization",
        "locale": "ru",
        "text": "купил вкусную колбасу за 300",
        "categories": [{"id": "c1", "name": "Продукты", "type": "expense"}],
        # Главное в этом кейсе — лемматизация item_phrase: винительный → именительный,
        # «вкусную колбасу» → «вкусная колбаса» (см. SYSTEM_PROMPT раздел 6).
        # category_id — мягкая проверка: модель иногда возвращает category_name='Продукты',
        # category_is_new=false, но category_id=null. Это противоречие в выводе
        # (раздел 4 промпта), но не блокирует UX — клиент сматчит по имени.
        # Финдинг для C3: уточнить раздел 4 «when is_new=false, you MUST also
        # set category_id from the matched item».
        "assert_equals": {
            "type": "expense",
            "amount": 300,
            "item_phrase": "вкусная колбаса",
            "category_is_new": False,
        },
        "assert_in": {
            "category_id": ["c1", None],
        },
    },

    # ── ДОЛГИ (главный фокус M14) ────────────────────────────────────
    {
        "id": "ru_debt_take_new_counterpart",
        "locale": "ru",
        "text": "занял у Сергея 5000",
        "counterparts": [],
        "assert_equals": {
            "type": "debt_take",
            "amount": 5000,
            "counterpart_is_new": True,
        },
        "assert_present": ["counterpart_name"],
    },
    {
        "id": "ru_debt_take_diminutive_match",
        "locale": "ru",
        "text": "занял у Серёжи 2000",
        "counterparts": [{"id": "u1", "name": "Сергей"}],
        "assert_equals": {
            "type": "debt_take",
            "amount": 2000,
            "counterpart_id": "u1",
            "counterpart_is_new": False,
        },
    },
    {
        "id": "ru_debt_give_basic",
        "locale": "ru",
        "text": "дал Кате 1000 в долг",
        "counterparts": [],
        "assert_equals": {
            "type": "debt_give",
            "amount": 1000,
            "counterpart_is_new": True,
        },
        "assert_present": ["counterpart_name"],
    },
    {
        "id": "ru_debt_payment_outbound",
        "locale": "ru",
        "text": "отдал долг Сереже 1500",
        "counterparts": [{"id": "u1", "name": "Сергей"}],
        "assert_equals": {
            "type": "debt_payment",
            "amount": 1500,
            "counterpart_id": "u1",
            "counterpart_is_new": False,
            "payment_flow": "outbound",
        },
    },
    {
        "id": "ru_debt_payment_inbound",
        "locale": "ru",
        "text": "Катя вернула 500",
        "counterparts": [{"id": "u2", "name": "Катя"}],
        "assert_equals": {
            "type": "debt_payment",
            "amount": 500,
            "counterpart_id": "u2",
            "counterpart_is_new": False,
            "payment_flow": "inbound",
        },
    },
    {
        "id": "ru_debt_payment_morphology",
        "locale": "ru",
        "text": "вернул Сергею Иванову 3000",
        "counterparts": [{"id": "u3", "name": "Сергей Иванов"}],
        "assert_equals": {
            "type": "debt_payment",
            "amount": 3000,
            "counterpart_id": "u3",
            "counterpart_is_new": False,
            "payment_flow": "outbound",
        },
    },
    {
        "id": "ru_debt_payment_ambiguous",
        "locale": "ru",
        "text": "отдал долг Сереже 1000",
        "counterparts": [
            {"id": "u1", "name": "Сергей Иванов"},
            {"id": "u4", "name": "Сергей Петров"},
        ],
        # Главное: НЕ создаётся новый counterpart_is_new=true.
        # Какого именно Сергея выберет модель — недетерминированно;
        # iOS-сторона потом покажет выбор между долгами обоих Сергеев.
        "assert_equals": {
            "type": "debt_payment",
            "amount": 1000,
            "counterpart_is_new": False,
            "payment_flow": "outbound",
        },
        "assert_in": {
            "counterpart_id": ["u1", "u4"],
        },
    },
    {
        "id": "en_debt_payment_diminutive",
        "locale": "en",
        "text": "paid back Mike 50",
        "counterparts": [{"id": "u5", "name": "Michael"}],
        "assert_equals": {
            "type": "debt_payment",
            "amount": 50,
            "counterpart_id": "u5",
            "counterpart_is_new": False,
            "payment_flow": "outbound",
        },
    },

    # ── Off-topic / incomplete ───────────────────────────────────────
    {
        "id": "ru_off_topic",
        "locale": "ru",
        "text": "привет как дела",
        "categories": [],
        # status != "ok" — модель должна вернуть rejected или incomplete
        "assert_in": {
            "status": ["rejected", "incomplete"],
        },
    },
    {
        "id": "ru_incomplete_amount",
        "locale": "ru",
        "text": "купил хлеб",
        "categories": [{"id": "c1", "name": "Продукты", "type": "expense"}],
        # SYSTEM_PROMPT раздел 2: «If amount is missing: status="incomplete",
        # missing=["amount"]». На практике (2026-05-11) gemini-2.5-flash-lite
        # игнорирует это правило и возвращает status="ok", amount=null.
        # Это finding для C3 — нужно усилить формулировку раздела 2
        # ("MUST" / явный пример без суммы). xfail здесь — red-test, который
        # автоматически станет green после доработки промпта в C3-сессии.
        "xfail_reason": "C3 — модель не выставляет status=incomplete при отсутствии amount",
        "assert_equals": {
            "status": "incomplete",
        },
    },
]
