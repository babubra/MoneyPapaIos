// MonPapa iOS — Централизованный логгер на базе os.Logger
//
// Используем Apple Unified Logging System (iOS 14+) вместо print:
// - Уровни (debug/info/notice/error/fault).
// - Subsystem + category для фильтрации в Console.app.
// - Persistence (можно вытащить через OSLogStore в release-сборке).
// - Ленивая интерполяция — строки не форматируются, если уровень отключён.
//
// Использование:
//     MPLog.service.info("parseText [\(reqId, privacy: .public)] start")
//     MPLog.dashboard.debug("handleAIResult: \(description, privacy: .public)")
//     MPLog.service.error("decode failed: \(err.localizedDescription, privacy: .public)")
//
// ВАЖНО про privacy:
// - Числа (Int/Double) публичны по умолчанию.
// - Строки и CustomStringConvertible приватны по умолчанию — маскируются как <private>
//   в release-сборках. Для наших debug/info логов явно ставим `privacy: .public`,
//   иначе в TestFlight/Console не увидим значения.

import Foundation
import os

enum MPLog {
    private static let subsystem = "com.monpapa.ai"

    /// Сетевой клиент AI: HTTP-запросы, декодирование, ошибки.
    static let service = Logger(subsystem: subsystem, category: "service")

    /// UI-триггер ввода: AIInputBar (текст/голос — старт/конец/длительность).
    static let input = Logger(subsystem: subsystem, category: "input")

    /// Маршрутизация результата AI на DashboardView (ветки, поиск долга).
    static let dashboard = Logger(subsystem: subsystem, category: "dashboard")

    /// Применение результата AI в sheet'ах (AddTransaction/AddDebt).
    static let prefill = Logger(subsystem: subsystem, category: "prefill")

    /// Auto-learn: отправка маппингов item_phrase → category.
    static let autolearn = Logger(subsystem: subsystem, category: "autolearn")

    /// Авторизация устройства и AI-токены.
    static let auth = Logger(subsystem: subsystem, category: "auth")
}
