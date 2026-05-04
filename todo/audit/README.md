# Audit reports

Здесь лежат отчёты по блокам аудита из [`../claude_code_opus_4.7_plan.md`](../claude_code_opus_4.7_plan.md).

## Naming convention

`<ID>_<short_name>.md`

Примеры:
- `A1_backend_surface.md`
- `C1_ai_prompts.md`
- `B3_ui_smoothness.md`

## Формат отчёта

См. секцию "Формат сессии аудита" в [плане](../claude_code_opus_4.7_plan.md).

Кратко:
- Severity: 🔴 Critical / 🟡 Medium / 🟢 Low
- Каждый finding ссылается на `файл:строка`
- В конце — секция "Что не покрыли"

## Правила

- В сессиях аудита код **НЕ правится**, только пишутся отчёты
- Правки по findings — отдельные сессии (создавай отдельные ветки/worktrees)
- После завершения блока — обновить status tracker в плане
