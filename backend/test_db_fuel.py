import asyncio
from app.db.session import AsyncSessionLocal
from app.db.models import Transaction, CategoryMapping
from sqlalchemy.future import select

async def main():
    async with AsyncSessionLocal() as db:
        print("=== Latest 10 Transactions ===")
        res_tx = await db.execute(select(Transaction).order_by(Transaction.created_at.desc()).limit(10))
        txs = res_tx.scalars().all()
        for tx in txs:
            print(f"[{tx.transaction_date}] {tx.amount} {tx.currency} | CatID: {tx.category_id} | Text: '{tx.raw_text}'")
        if not txs:
            print("No transactions found.")

        print("\n=== Latest 10 Mappings ===")
        res_map = await db.execute(select(CategoryMapping).order_by(CategoryMapping.updated_at.desc()).limit(10))
        mappings = res_map.scalars().all()
        for m in mappings:
            print(f"Phrase: '{m.item_phrase}' -> Category: '{m.category_name}' (Weight: {m.weight})")
        if not mappings:
            print("No mappings found.")

if __name__ == "__main__":
    asyncio.run(main())
