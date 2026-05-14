"""Diagnostic-инструмент для замера prompt-cache hit rate у aitunnel.ru.

Шлёт N идентичных запросов подряд через настоящий aitunnel и печатает построчно
`attempt prompt completion cached elapsed_ms`. Используется для AB-сравнения
до/после правок `_call_ai_text` (см. #1 в `todo/audit/C1_C2_ai_layer.md`).

Запуск:
    cd backend && source venv/bin/activate
    python check_cache.py                              # 1 запрос, без hints (baseline)
    python check_cache.py --repeat 10                  # 10 запросов подряд, без hints
    python check_cache.py --repeat 10 --user-key u0    # с user= и prompt_cache_key=u0
    python check_cache.py --repeat 10 --user-key u0 --no-cache-key  # только user=, без extra_body

Стоимость одного запроса на gemini-2.5-flash-lite ≈ $0.002. 10 запросов ≈ $0.02.
"""
import argparse
import asyncio
import time

from openai import AsyncOpenAI

from app.core.config import get_settings
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt

settings = get_settings()


async def one_call(
    client: AsyncOpenAI,
    user_prompt: str,
    *,
    user_key: str | None,
    send_cache_key: bool,
) -> dict:
    """Один вызов aitunnel. Возвращает dict с usage-полями + elapsed_ms."""
    kwargs: dict = {
        "model": settings.AI_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0,
        "max_tokens": 1024,
        "response_format": {"type": "json_object"},
    }
    if user_key:
        kwargs["user"] = user_key
        if send_cache_key:
            kwargs["extra_body"] = {"prompt_cache_key": user_key}

    t0 = time.perf_counter()
    response = await client.chat.completions.create(**kwargs)
    elapsed_ms = int((time.perf_counter() - t0) * 1000)

    usage = response.usage
    cached = 0
    details = getattr(usage, "prompt_tokens_details", None)
    if details is not None:
        cached = getattr(details, "cached_tokens", 0) or 0

    return {
        "prompt": usage.prompt_tokens or 0,
        "completion": usage.completion_tokens or 0,
        "total": usage.total_tokens or 0,
        "cached": cached,
        "elapsed_ms": elapsed_ms,
    }


async def main(args: argparse.Namespace) -> None:
    client = AsyncOpenAI(
        api_key=settings.AITUNNEL_API_KEY,
        base_url=settings.AITUNNEL_BASE_URL,
        timeout=30.0,
    )

    VARYING_TEXTS = [
        "купил хлеба за 400 рублей вчера",
        "потратил 1500 на бензин",
        "оплатил подписку Netflix 500",
        "получил зарплату 80000",
        "купил молоко за 90",
        "обед в кафе 1200",
        "такси 350 рублей",
        "кофе утром 250",
        "оплата интернета 700",
        "купил книгу 1100",
    ]

    def _build(text: str) -> str:
        return build_ai_prompt(
            user_text=text,
            categories=[{"id": "1", "name": "Продукты", "type": "expense"}],
            counterparts=[],
            today="2026-04-02",
        )

    if args.vary:
        user_prompts = [_build(VARYING_TEXTS[i % len(VARYING_TEXTS)]) for i in range(args.repeat)]
    else:
        user_prompts = [_build("купил хлеба за 400 рублей вчера")] * args.repeat

    mode_desc = (
        f"user={args.user_key!r}, cache_key={'on' if not args.no_cache_key else 'off'}"
        if args.user_key
        else "no hints (baseline)"
    )
    print(f"# model={settings.AI_MODEL}, repeat={args.repeat}, mode: {mode_desc}")
    print(f"# {'attempt':>7} {'prompt':>6} {'compl':>5} {'total':>6} {'cached':>6} {'elapsed':>8}")

    hits = 0
    sum_prompt = 0
    sum_cached = 0
    try:
        for i in range(1, args.repeat + 1):
            try:
                r = await one_call(
                    client,
                    user_prompts[i - 1],
                    user_key=args.user_key,
                    send_cache_key=not args.no_cache_key,
                )
            except Exception as e:
                print(f"  {i:>7} ERROR {e!r}")
                continue

            hit_mark = "✓" if r["cached"] > 0 else " "
            print(
                f"  {i:>7} {r['prompt']:>6} {r['completion']:>5} {r['total']:>6} "
                f"{r['cached']:>6} {r['elapsed_ms']:>6}ms {hit_mark}"
            )
            sum_prompt += r["prompt"]
            sum_cached += r["cached"]
            if r["cached"] > 0:
                hits += 1
            if args.delay > 0 and i < args.repeat:
                await asyncio.sleep(args.delay)
    finally:
        await client.close()

    if args.repeat > 0:
        hit_rate = hits / args.repeat * 100
        print(
            f"\n# Summary: hits={hits}/{args.repeat} ({hit_rate:.0f}%), "
            f"sum_prompt={sum_prompt}, sum_cached={sum_cached} "
            f"(billable_prompt={sum_prompt - sum_cached})"
        )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--repeat", type=int, default=1, help="Сколько одинаковых запросов сделать подряд (default: 1)")
    p.add_argument(
        "--user-key",
        type=str,
        default=None,
        help='Строка, которую слать как user= (и prompt_cache_key, если не задан --no-cache-key). '
             'Если не указано — никаких hints не передаётся (baseline-режим).',
    )
    p.add_argument(
        "--no-cache-key",
        action="store_true",
        help="При указанном --user-key передавать только user=, без extra_body.prompt_cache_key.",
    )
    p.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="Пауза между запросами в секундах (default: 0).",
    )
    p.add_argument(
        "--vary",
        action="store_true",
        help=(
            "Шлёт разные user_text на каждом запросе (имитирует реальный prod-трафик). "
            "Без флага — все N запросов идентичны (best-case для cache)."
        ),
    )
    return p.parse_args()


if __name__ == "__main__":
    asyncio.run(main(parse_args()))
