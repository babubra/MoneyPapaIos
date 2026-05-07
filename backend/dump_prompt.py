"""Утилита: выгрузить ТОЧНЫЙ prompt, который улетает в Gemini для конкретного юзера.

Назначение: скармливать одинаковый prompt разным моделям (через aitunnel/Anthropic/OpenAI/Qwen)
и сравнивать ответы — без необходимости запускать full backend.

Берёт categories/counterparts/mappings прямо из БД (как они хранятся для синхронизации),
строит user_prompt через тот же `build_ai_prompt`, что и продакшн, и пишет всё в один файл.

Запуск:
    docker compose exec -T backend python dump_prompt.py \
        --user-id 19 \
        --text "Запиши в категорию молочные продукты кефир за 500 рублей" \
        --locale ru \
        --out /tmp/prompt.txt

Если backend крутится локально (без docker), просто:
    cd backend && source venv/bin/activate && python dump_prompt.py --user-id 19 --text "..."

Вывод по умолчанию — stdout. С `--out FILE` — записывает в файл.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

# Backend импортируется как пакет — путь sys.path обычно уже верный из docker WORKDIR=/app.
# Если запускаешь не из docker — добавь venv и cd backend.
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt
from app.db.models import CategoryMapping, Category, Counterpart
from app.db.session import AsyncSessionLocal


async def fetch_context(db: AsyncSession, user_id: int) -> dict:
    """Грузит категории/контрагентов/маппинги юзера из БД в формате,
    идентичном тому, что клиент передаёт в /parse + что бэкенд грузит сам."""
    # Категории — клиент передаёт в формате CategoryContext: {id, name, type}.
    # Используем client_id как id (offline-first).
    cat_q = await db.execute(
        select(Category).where(Category.user_id == user_id, Category.deleted_at.is_(None))
    )
    categories = []
    for c in cat_q.scalars().all():
        if not c.client_id:
            continue
        # Если есть parent — собираем имя в формате "Родитель / Дочерняя",
        # как это делает iOS-клиент в DashboardView.aiCategoryDTOs.
        # (На бэке у Category есть только parent_id; склеить имя — отдельный JOIN.)
        categories.append({
            "id": c.client_id,
            "name": c.name,
            "type": c.type,
        })

    # Контрагенты — формат CounterpartContext: {id, name}.
    cp_q = await db.execute(
        select(Counterpart).where(Counterpart.user_id == user_id, Counterpart.deleted_at.is_(None))
    )
    counterparts = [
        {"id": cp.client_id, "name": cp.name}
        for cp in cp_q.scalars().all()
        if cp.client_id
    ]

    # Маппинги — формат как в _load_user_mappings (топ-30 по weight + updated_at).
    map_q = await db.execute(
        select(CategoryMapping)
        .where(CategoryMapping.user_id == user_id)
        .order_by(CategoryMapping.weight.desc(), CategoryMapping.updated_at.desc())
        .limit(30)
    )
    mappings = [
        {"item_phrase": m.item_phrase, "category_name": m.category_name, "weight": m.weight}
        for m in map_q.scalars().all()
    ]

    return {
        "categories": categories,
        "counterparts": counterparts,
        "mappings": mappings,
    }


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user-id", type=int, required=True, help="user_id из таблицы users")
    ap.add_argument("--text", required=True, help="Текст транзакции (как юзер ввёл)")
    ap.add_argument("--locale", default="ru", help="ru/en/de/... (default: ru)")
    ap.add_argument("--today", default=None, help="YYYY-MM-DD (default: сегодня)")
    ap.add_argument("--out", default=None, help="Путь к файлу. Без флага — stdout.")
    ap.add_argument("--no-mappings", action="store_true",
                    help="Выгрузить prompt БЕЗ user_mappings (для проверки эффекта C1.5)")
    args = ap.parse_args()

    today_str = args.today or date.today().isoformat()

    async with AsyncSessionLocal() as db:
        ctx = await fetch_context(db, args.user_id)

    mappings = None if args.no_mappings else (ctx["mappings"] or None)

    user_prompt = build_ai_prompt(
        user_text=args.text,
        categories=ctx["categories"],
        counterparts=ctx["counterparts"],
        today=today_str,
        locale=args.locale,
        mappings=mappings,
    )

    output = (
        "=" * 78 + "\n"
        f"DUMP — user_id={args.user_id} locale={args.locale} today={today_str}\n"
        f"  categories: {len(ctx['categories'])}, counterparts: {len(ctx['counterparts'])}, "
        f"mappings: {0 if args.no_mappings else len(ctx['mappings'])} "
        f"({'OMITTED' if args.no_mappings else 'INCLUDED'})\n"
        + "=" * 78 + "\n\n"
        "[SYSTEM PROMPT]\n"
        + SYSTEM_PROMPT
        + "\n\n" + "-" * 78 + "\n\n"
        "[USER PROMPT]\n"
        + user_prompt
        + "\n"
    )

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"✓ Записано в {args.out} ({len(output)} символов)")
    else:
        sys.stdout.write(output)

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
