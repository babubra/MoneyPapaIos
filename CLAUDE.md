# Monpapaios

Repo layout:
- `backend/` — backend service
- `Monpapa/` — frontend client
- `todo/` — plans and audit reports
- `todo/audit/` — production-readiness audit findings

## Production readiness audit

Идёт постепенный аудит готовности к проду. Глобальный план:
**[`todo/claude_code_opus_4.7_plan.md`](todo/claude_code_opus_4.7_plan.md)**

Чтобы продолжить аудит в новой сессии:
> "Прочитай `todo/claude_code_opus_4.7_plan.md` и начни с блока **<ID>**. Отчёт положи в `todo/audit/<ID>_<name>.md`."

Правила аудита:
- В сессиях аудита код **НЕ правится**, только отчёты в `todo/audit/`
- Формат отчёта описан в плане (severity 🔴/🟡/🟢, ссылка на `файл:строка`, секция "Что не покрыли")
- После каждой сессии — обновить status tracker в плане
