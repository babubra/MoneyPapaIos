import asyncio
from openai import AsyncOpenAI
from app.core.config import get_settings
from app.core.system_prompt import SYSTEM_PROMPT, build_ai_prompt

settings = get_settings()

async def main():
    client = AsyncOpenAI(
        api_key=settings.AITUNNEL_API_KEY,
        base_url=settings.AITUNNEL_BASE_URL,
    )
    
    user_prompt = build_ai_prompt(
        user_text="купил хлеба за 400 рублей вчера",
        categories=[{"id":"1","name":"Продукты","type":"expense"}],
        counterparts=[],
        today="2026-04-02",
    )
    
    print(f"Отправляем запрос...")
    response = await client.chat.completions.create(
        model=settings.AI_MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.1,
        response_format={"type": "json_object"},
    )
    
    print("\n--- Результат ---")
    print(response.choices[0].message.content)
    
    print("\n--- Использование токенов (Usage) ---")
    usage = response.usage
    print(f"Промт токенов: {usage.prompt_tokens}")
    print(f"Вывод токенов: {usage.completion_tokens}")
    print(f"Всего токенов: {usage.total_tokens}")
    
    # Проверяем детализацию OpenAI (если провайдер её поддерживает)
    if hasattr(usage, 'prompt_tokens_details') and usage.prompt_tokens_details:
        print(f"Из них КЕШИРОВАНО: {getattr(usage.prompt_tokens_details, 'cached_tokens', 0)}")
    
    print(f"\nСырой объект usage:\n{usage}")

if __name__ == "__main__":
    asyncio.run(main())
