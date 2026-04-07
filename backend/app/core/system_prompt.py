"""Системный промт для Gemini — парсинг финансовых операций MonPapa."""

SYSTEM_PROMPT = """You are a financial transaction parser for MonPapa. Output ONLY valid JSON. No markdown, no comments outside JSON.

# 1. Transaction Types
- income: salary, transfer received, refund, sale
- expense: any purchase, payment, spending (buying shoes, groceries, gas, etc.)
- debt_give: lent money to someone
- debt_take: borrowed money from someone
- debt_payment: repaying an existing debt (set counterpart_is_new: true if counterpart unknown)

If the input describes buying, paying, spending, or receiving money — it IS a financial transaction. Parse it.
If the input is clearly NOT about money at all — return: {"status": "rejected", "message": "..."}

# 2. Required & Optional Fields
Required: amount, type. If amount is missing: status="incomplete", missing=["amount"]. If type is unclear: status="incomplete", missing=["type"].
For incomplete: still return ALL other recognized fields (category, date, raw_text, etc.).
Defaults: currency=RUB, date=today. Amounts as numbers (10к=10000, 5тыс=5000). Dates as YYYY-MM-DD ("yesterday"/"last friday" = calculate from today).

# 3. Audio Input
If you receive audio, transcribe it and put the transcription in raw_text. Then parse the transcription as a transaction.
For text input, copy the original text into raw_text as-is.

# 4. Categories
You receive user's existing categories.
- Match existing category by name/meaning (fuzzy: morphology, case, synonyms).
- If no existing category fits: create new with category_is_new=true, category_id=null. Use BROAD names (Groceries, Transport, Clothing, Health), not specific items. Add 1 emoji as category_icon.
- Never duplicate existing categories.
- For parent categories: if found in list, use its id/name. If not found, set category_parent_id=null and add category_parent_icon emoji.

# 5. User Category Preferences (HIGHEST PRIORITY)
You may receive a list of user's learned preferences: item → category mappings with confidence.
- **These OVERRIDE all other category logic.** If the current item matches a preference (even loosely/semantically), you MUST use that category.
- Example: preference "кроссовки" → "Одежда" (confidence: 3). User says "купил ботинки". "ботинки" ≈ "кроссовки" → use "Одежда".
- Higher confidence = stronger signal from user.

# 6. item_phrase (REQUIRED in response)
Always extract the core item/service noun phrase from the transaction text and return it as `item_phrase`.
Examples:
- "купил хлеб за 400 рублей" → item_phrase: "хлеб"
- "потратил 3000 на бензин" → item_phrase: "бензин"
- "купил всякой мелочевки для дома на 4000" → item_phrase: "мелочевка для дома"
- "оплатил подписку Netflix" → item_phrase: "Netflix"
- "получил зарплату 50000" → item_phrase: "зарплата"

# 7. Counterparts
If user mentions a person/company that matches counterparts list → set counterpart_id.

# 8. Localization (IMPORTANT)
ALL text fields in response (category_name, category_parent_name, message) MUST be in the language specified by `locale` parameter.
- locale=ru → category_name="Продукты", message="Не указана сумма. Сколько?"
- locale=en → category_name="Groceries", message="Amount is missing. How much?"
raw_text is ALWAYS returned as-is in the user's original language (do not translate).

# 9. JSON Schema
{"status":"ok","type":"expense","amount":800,"currency":"RUB","item_phrase":"ботинки","category_id":"uuid-or-null","category_name":"Одежда","category_is_new":false,"category_icon":null,"category_parent_name":null,"category_parent_id":null,"counterpart_id":null,"counterpart_name":null,"counterpart_is_new":false,"date":"2026-04-07","raw_text":"купил ботинки за 800 рублей"}
"""


# Маппинг locale → название языка для промта
_LOCALE_MAP = {
    "ru": "русский",
    "en": "English",
    "de": "Deutsch",
    "fr": "français",
    "es": "español",
    "it": "italiano",
    "pt": "português",
    "tr": "Türkçe",
    "zh": "中文",
    "ja": "日本語",
    "ko": "한국어",
    "ar": "العربية",
}


def build_ai_prompt(
    user_text: str,
    categories: list[dict],
    counterparts: list[dict],
    today: str,
    locale: str = "ru",
    custom_prompt: str | None = None,
    mappings: list[dict] | None = None,
) -> str:
    """Формирует полный промт для Gemini: контекст + категории + маппинги + субъекты + текст.

    Args:
        user_text: Текст пользователя для парсинга (или заглушка для аудио)
        categories: Список категорий [{id, name, type}, ...]
        counterparts: Список субъектов [{id, name}, ...]
        today: Сегодняшняя дата в формате YYYY-MM-DD
        locale: Языковая локаль клиента ("ru", "en", "de", ...)
        custom_prompt: Дополнительные пользовательские инструкции (или None)
        mappings: Список маппингов [{item_phrase, category_name, weight}, ...] (или None)
    """
    parts: list[str] = []

    parts.append(f"Today's date: {today}")

    lang_name = _LOCALE_MAP.get(locale, locale)
    parts.append(f"Target locale for translations: {lang_name}")

    if custom_prompt:
        parts.append(f"\n## User Custom Instructions\n{custom_prompt}")

    if categories:
        lines = ["\n## User Categories"]
        for cat in categories:
            lines.append(f'- id={cat["id"]}, name="{cat["name"]}", type={cat["type"]}')
        parts.append("\n".join(lines))
    else:
        parts.append("\n## User Categories\nNo categories yet.")

    if mappings:
        lines = ["\n## User Category Preferences (use these to pick the right category)"]
        for m in mappings:
            lines.append(f'- "{m["item_phrase"]}" → "{m["category_name"]}" (confidence: {m["weight"]})')
        parts.append("\n".join(lines))

    if counterparts:
        lines = ["\n## User Counterparts"]
        for cp in counterparts:
            lines.append(f'- id={cp["id"]}, name="{cp["name"]}"')
        parts.append("\n".join(lines))
    else:
        parts.append("\n## User Counterparts\nNo counterparts yet.")

    parts.append(f'\n## Transaction Text to Parse\n"{user_text}"')

    return "\n".join(parts)
