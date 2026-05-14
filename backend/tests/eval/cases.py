"""Мок-кейсы regression нашего обработчика.

Назначение: «когда AI возвращает X, наш Python-код корректно превращает в Y».
Не путать с tests/golden/cases.py — там реальный AI-вызов и проверка качества модели.

Каждый кейс — словарь:
- id: уникальный идентификатор (для pytest -k)
- text: текст пользователя (передаётся в build_ai_prompt)
- categories / counterparts / mappings: контекст для prompt-а
- locale: ru/en
- mock_response: что вернёт «AI» (строка ИЛИ dict; dict будет JSON-encoded)
- expected_subset: подмножество, которое должно быть в распарсенном результате
- xfail_reason: если задан — кейс помечен xfail
"""

CASES = [
    {
        "id": "m1_income_ok",
        "text": "зарплата 50000",
        "categories": [{"id": "c1", "name": "Зарплата", "type": "income"}],
        "counterparts": [],
        "locale": "ru",
        "mock_response": {
            "status": "ok",
            "type": "income",
            "amount": 50000,
            "currency": "RUB",
            "item_phrase": "зарплата",
            "category_id": "c1",
            "category_name": "Зарплата",
            "category_is_new": False,
            "raw_text": "зарплата 50000",
        },
        "expected_subset": {
            "status": "ok",
            "type": "income",
            "amount": 50000,
            "category_id": "c1",
            "category_is_new": False,
        },
    },
    {
        "id": "m2_debt_payment_with_counterpart_id",
        "text": "отдал Сергею 1500",
        "categories": [],
        "counterparts": [{"id": "u1", "name": "Сергей"}],
        "locale": "ru",
        "mock_response": {
            "status": "ok",
            "type": "debt_payment",
            "amount": 1500,
            "currency": "RUB",
            "item_phrase": None,
            "counterpart_id": "u1",
            "counterpart_name": "Сергей",
            "counterpart_is_new": False,
            "payment_flow": "outbound",
            "raw_text": "отдал Сергею 1500",
        },
        "expected_subset": {
            "type": "debt_payment",
            "counterpart_id": "u1",
            "counterpart_is_new": False,
            "payment_flow": "outbound",
        },
    },
    {
        "id": "m3_null_string_category_normalized",
        "text": "купил что-то 100",
        "categories": [],
        "counterparts": [],
        "locale": "ru",
        # AI прислал строку "null" в whitelisted-поле — _normalize_null_strings
        # должен превратить её в реальный None.
        "mock_response": {
            "status": "ok",
            "type": "expense",
            "amount": 100,
            "category_id": "null",
            "category_name": "None",
            "category_icon": "",
            "raw_text": "купил что-то 100",
        },
        "expected_subset": {
            "type": "expense",
            "amount": 100,
            "category_id": None,
            "category_name": None,
            "category_icon": None,
        },
    },
    {
        "id": "m4_markdown_wrapped_response",
        "text": "купил хлеб 50",
        "categories": [{"id": "c1", "name": "Продукты", "type": "expense"}],
        "counterparts": [],
        "locale": "ru",
        # Полная markdown-обёртка с trailing comma — sanitize должен спасти.
        "mock_response": (
            '```json\n'
            '{"status": "ok", "type": "expense", "amount": 50, '
            '"category_id": "c1", "category_name": "Продукты",}\n'
            '```'
        ),
        "expected_subset": {
            "type": "expense",
            "amount": 50,
            "category_id": "c1",
        },
    },
    {
        "id": "m5_off_topic_status",
        "text": "привет как дела",
        "categories": [],
        "counterparts": [],
        "locale": "ru",
        "mock_response": {
            "status": "rejected",
            "message": "Это не похоже на финансовую операцию.",
        },
        "expected_subset": {
            "status": "rejected",
        },
    },
    {
        "id": "m6_url_in_raw_text_through_sanitize",
        "text": "оплатил подписку https://netflix.com 999",
        "categories": [],
        "counterparts": [],
        "locale": "ru",
        # AI прислал JSON в markdown-обёртке — это заставляет _sanitize_json
        # вступить в работу (без обёртки прямой json.loads сразу бы прошёл).
        # Sanitize снимет markdown — и заодно зарежет всё после '//' в URL,
        # сломав raw_text. Это сценарий, который мы хотим починить в #19.
        # При закрытии #19 тест станет green автоматически.
        "mock_response": (
            "```json\n"
            '{"status":"ok","type":"expense","amount":999,'
            '"raw_text":"оплатил подписку https://netflix.com 999"}\n'
            "```"
        ),
        "expected_subset": {
            "type": "expense",
            "amount": 999,
            "raw_text": "оплатил подписку https://netflix.com 999",
        },
        "xfail_reason": "C2.19 — _sanitize_json режет URL внутри строк JSON",
    },
]
