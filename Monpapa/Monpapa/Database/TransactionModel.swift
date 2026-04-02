// MonPapa iOS — SwiftData модель: Transaction (Транзакция)

import Foundation
import SwiftData

@Model
final class TransactionModel {

    /// ID на сервере — nil если ещё не синхронизировано
    @Attribute(.unique)
    var serverId: Int?

    /// Тип: income / expense (хранится как строка)
    var typeRaw: String

    /// Сумма: 1500.50 (Decimal для точности, хранится как String в SwiftData)
    var amountString: String

    /// Валюта: «RUB», «USD», «EUR»
    var currency: String

    /// Комментарий: «Обед в кафе»
    var comment: String?

    /// Оригинальный текст от AI: «потратил 500 на продукты»
    var rawText: String?

    /// UUID для защиты от дубликатов при синхронизации
    @Attribute(.unique)
    var clientId: String?

    /// Дата операции (когда реально произошла)
    var transactionDate: Date

    /// Путь к фото чека (опционально)
    var attachmentPath: String?

    /// Дата создания записи
    var createdAt: Date

    /// Дата последнего обновления
    var updatedAt: Date

    // MARK: - Связи

    /// Категория (опционально)
    @Relationship
    var category: CategoryModel?

    // MARK: - Вычисляемые свойства

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var amount: Decimal {
        get { Decimal(string: amountString) ?? 0 }
        set { amountString = "\(newValue)" }
    }

    var amountDouble: Double {
        Double(truncating: amount as NSDecimalNumber)
    }

    // MARK: - Инициализатор

    init(
        type: TransactionType,
        amount: Decimal,
        currency: String = "RUB",
        transactionDate: Date,
        comment: String? = nil,
        rawText: String? = nil,
        category: CategoryModel? = nil,
        attachmentPath: String? = nil,
        serverId: Int? = nil
    ) {
        self.typeRaw = type.rawValue
        self.amountString = "\(amount)"
        self.currency = currency
        self.transactionDate = transactionDate
        self.comment = comment
        self.rawText = rawText
        self.category = category
        self.attachmentPath = attachmentPath
        self.serverId = serverId
        self.clientId = UUID().uuidString
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
