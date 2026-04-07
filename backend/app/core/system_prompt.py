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

# 4. Categories & ai_hint (HIGHEST PRIORITY RULE)
You receive user's existing categories with optional ai_hint field.
- **ai_hint OVERRIDES all other logic.** If a category has ai_hint and the transaction matches that hint (even loosely), you MUST use that category. Example: category "Groceries" with ai_hint "shoes" — if user buys shoes, use "Groceries" because the user explicitly trained this mapping.
- If no hint matches: match an existing category by name/meaning (fuzzy: morphology, case, synonyms).
- If no existing category fits: create new with category_is_new=true, category_id=null. Use BROAD names (Groceries, Transport, Clothing, Health), not specific items. Add 1 emoji as category_icon.
- Never duplicate existing categories.
- For parent categories: if found in list, use its id/name. If not found, set category_parent_id=null and add category_parent_icon emoji.

# 5. Counterparts
If user mentions a person/company that matches counterparts list → set counterpart_id.

# 6. Localization (IMPORTANT)
ALL text fields in response (category_name, category_parent_name, message) MUST be in the language specified by `locale` parameter.
- locale=ru → category_name="Продукты", message="Не указана сумма. Сколько?"
- locale=en → category_name="Groceries", message="Amount is missing. How much?"
raw_text is ALWAYS returned as-is in the user's original language (do not translate).

# 7. JSON Schema
{"status":"ok","type":"expense","amount":800,"currency":"RUB","category_id":"uuid-or-null","category_name":"Одежда","category_is_new":false,"category_icon":null,"category_parent_name":null,"category_parent_id":null,"counterpart_id":null,"counterpart_name":null,"counterpart_is_new":false,"date":"2026-04-07","raw_text":"купил ботинки за 800 рублей"}
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
) -> str:
    """Формирует полный промт для Gemini: контекст + категории + субъекты + текст.

    Args:
        user_text: Текст пользователя для парсинга (или заглушка для аудио)
        categories: Список категорий [{id, name, type, ai_hint}, ...]
        counterparts: Список субъектов [{id, name, ai_hint}, ...]
        today: Сегодняшняя дата в формате YYYY-MM-DD
        locale: Языковая локаль клиента ("ru", "en", "de", ...)
        custom_prompt: Дополнительные пользовательские инструкции (или None)
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
            hint = f' (ai_hint: {cat["ai_hint"]})' if cat.get("ai_hint") else ""
            lines.append(f'- id={cat["id"]}, name="{cat["name"]}", type={cat["type"]}{hint}')
        parts.append("\n".join(lines))
    else:
        parts.append("\n## User Categories\nNo categories yet.")

    if counterparts:
        lines = ["\n## User Counterparts"]
        for cp in counterparts:
            hint = f' (ai_hint: {cp["ai_hint"]})' if cp.get("ai_hint") else ""
            lines.append(f'- id={cp["id"]}, name="{cp["name"]}"{hint}')
        parts.append("\n".join(lines))
    else:
        parts.append("\n## User Counterparts\nNo counterparts yet.")

    parts.append(f'\n## Transaction Text to Parse\n"{user_text}"')

    return "\n".join(parts)
