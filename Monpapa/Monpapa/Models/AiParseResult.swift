// MonPapa iOS — AI Parse Result
// Модели ответа от POST /api/v1/ai/parse и /api/v1/ai/parse-audio

import Foundation

// MARK: - Ответ от AI (успешный парсинг)

struct AiParseResult: Codable, Identifiable, Equatable {
    /// Уникальный ID для SwiftUI .sheet(item:)
    var id = UUID()
    let status: AiParseStatus

    // Основные поля транзакции
    let type: String?           // "income" | "expense" | "debt_give" | "debt_take" | "debt_payment"
    let amount: Double?
    let currency: String?       // "RUB" | "USD" | ...
    let date: String?           // "YYYY-MM-DD"
    let rawText: String?        // Исходный текст
    let itemPhrase: String?     // Ключевое слово товара/услуги (для Auto-Learn)

    // Категория
    let categoryId: String?
    let categoryName: String?
    let categoryIsNew: Bool?
    let categoryIcon: String?       // emoji, если создаётся новая
    let categoryParentName: String?
    let categoryParentId: String?
    let categoryParentIcon: String?  // emoji родительской, если тоже новая

    // Контрагент
    let counterpartId: String?
    let counterpartName: String?
    let counterpartIsNew: Bool?

    // Долги
    let dueDate: String?        // "YYYY-MM-DD" — срок возврата (опционально)
    let paymentFlow: String?    // "inbound" (мне возвращают) | "outbound" (я возвращаю)

    // Сообщение для incomplete / rejected
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case type, amount, currency, date
        case rawText        = "raw_text"
        case itemPhrase     = "item_phrase"
        case categoryId     = "category_id"
        case categoryName   = "category_name"
        case categoryIsNew  = "category_is_new"
        case categoryIcon   = "category_icon"
        case categoryParentName = "category_parent_name"
        case categoryParentId   = "category_parent_id"
        case categoryParentIcon = "category_parent_icon"
        case counterpartId   = "counterpart_id"
        case counterpartName = "counterpart_name"
        case counterpartIsNew = "counterpart_is_new"
        case dueDate         = "due_date"
        case paymentFlow     = "payment_flow"
        case message
    }
}

enum AiParseStatus: String, Codable {
    case ok         = "ok"
    case incomplete = "incomplete"   // не хватает суммы или типа
    case rejected   = "rejected"     // нефинансовый запрос
}
