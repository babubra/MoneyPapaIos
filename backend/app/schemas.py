"""Pydantic-схемы для Фазы 1 — Auth и AI-парсинг."""

from pydantic import BaseModel, Field


# ── Auth ─────────────────────────────────────────────────────────

class DeviceAuthRequest(BaseModel):
    """Запрос регистрации/обновления устройства."""
    device_id: str = Field(..., min_length=36, max_length=36, description="UUID устройства из iOS Keychain")


class TokenResponse(BaseModel):
    """Ответ с Bearer-токеном."""
    access_token: str
    token_type: str = "bearer"


# ── AI-парсинг ────────────────────────────────────────────────────

class CategoryContext(BaseModel):
    """Категория пользователя, передаваемая клиентом при AI-запросе."""
    id: str = Field(..., description="Локальный ID категории (из SwiftData)")
    name: str = Field(..., description="Название (или 'Родитель / Дочерняя')")
    type: str = Field(..., pattern=r"^(income|expense)$")
    ai_hint: str | None = None


class CounterpartContext(BaseModel):
    """Контрагент пользователя, передаваемый клиентом при AI-запросе."""
    id: str = Field(..., description="Локальный ID контрагента (из SwiftData)")
    name: str
    ai_hint: str | None = None


class ParseTextRequest(BaseModel):
    """Тело запроса для текстового парсинга."""
    text: str = Field(..., min_length=1, max_length=500)
    categories: list[CategoryContext] = Field(default_factory=list)
    counterparts: list[CounterpartContext] = Field(default_factory=list)
    locale: str = Field(default="ru", max_length=5, description="Языковая локаль клиента (ru, en, de, ...)")


class RateLimitInfo(BaseModel):
    """Информация о лимитах текущего устройства."""
    requests_today: int
    requests_limit: int
    requests_remaining: int
