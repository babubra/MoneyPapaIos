// MonPapa iOS — Общие Enum'ы для моделей данных

import Foundation

/// Тип транзакции / категории
enum TransactionType: String, Codable, CaseIterable {
    case income
    case expense

    var displayName: String {
        switch self {
        case .income: String(localized: "Доход")
        case .expense: String(localized: "Расход")
        }
    }
}

/// Направление долга
enum DebtDirection: String, Codable, CaseIterable {
    case gave    // Я дал в долг (мне должны)
    case took    // Я взял в долг (я должен)

    var displayName: String {
        switch self {
        case .gave: String(localized: "Дал в долг")
        case .took: String(localized: "Взял в долг")
        }
    }
}
