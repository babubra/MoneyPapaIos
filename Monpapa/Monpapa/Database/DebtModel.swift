// MonPapa iOS — SwiftData модели: Debt + DebtPayment

import Foundation
import SwiftData

// MARK: - Debt (Долг)

@Model
final class DebtModel {

    /// ID на сервере
    @Attribute(.unique)
    var serverId: Int?

    /// Направление: gave / took
    var directionRaw: String

    /// Сумма долга (как строка для точности Decimal)
    var amountString: String

    /// Сколько уже выплачено
    var paidAmountString: String

    /// Валюта
    var currency: String

    /// Комментарий: «На ремонт квартиры»
    var comment: String?

    /// Оригинальный текст от AI
    var rawText: String?

    /// UUID для защиты от дубликатов
    @Attribute(.unique)
    var clientId: String?

    /// Дата возникновения долга
    var debtDate: Date

    /// Срок возврата долга (опционально)
    var dueDate: Date?

    /// Закрыт ли долг
    var isClosed: Bool

    /// Дата создания записи
    var createdAt: Date = Date()

    /// Дата обновления
    var updatedAt: Date = Date()

    /// Soft delete: nil = активен, Date = удалён
    var deletedAt: Date?

    // MARK: - Связи

    /// Контрагент (с кем долг)
    @Relationship
    var counterpart: CounterpartModel?

    /// Платежи по долгу
    @Relationship(deleteRule: .cascade, inverse: \DebtPaymentModel.debt)
    var payments: [DebtPaymentModel] = []

    // MARK: - Вычисляемые свойства

    var direction: DebtDirection {
        get { DebtDirection(rawValue: directionRaw) ?? .gave }
        set { directionRaw = newValue.rawValue }
    }

    var amount: Decimal {
        get { Decimal(string: amountString) ?? 0 }
        set { amountString = "\(newValue)" }
    }

    var paidAmount: Decimal {
        get {
            // Единый источник правды — сумма реальных платежей
            payments
                .filter { $0.deletedAt == nil }
                .reduce(Decimal(0)) { $0 + $1.amount }
        }
        set { paidAmountString = "\(newValue)" }
    }

    /// Остаток долга
    var remainingAmount: Decimal {
        amount - paidAmount
    }

    /// Просрочен ли долг (есть срок, не закрыт, срок прошёл)
    var isOverdue: Bool {
        guard let dueDate, !isClosed else { return false }
        return dueDate < Date()
    }

    /// Дней до срока возврата (отрицательное = просрочка)
    var daysUntilDue: Int? {
        guard let dueDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: dueDate).day
    }

    // MARK: - Инициализатор

    init(
        direction: DebtDirection,
        amount: Decimal,
        debtDate: Date,
        dueDate: Date? = nil,
        currency: String = "RUB",
        comment: String? = nil,
        rawText: String? = nil,
        counterpart: CounterpartModel? = nil,
        serverId: Int? = nil
    ) {
        self.directionRaw = direction.rawValue
        self.amountString = "\(amount)"
        self.paidAmountString = "0"
        self.currency = currency
        self.debtDate = debtDate
        self.dueDate = dueDate
        self.comment = comment
        self.rawText = rawText
        self.counterpart = counterpart
        self.isClosed = false
        self.serverId = serverId
        self.clientId = UUID().uuidString
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - DebtPayment (Платёж по долгу)

@Model
final class DebtPaymentModel {

    /// ID на сервере
    @Attribute(.unique)
    var serverId: Int?

    /// UUID для защиты от дубликатов при синхронизации
    @Attribute(.unique)
    var clientId: String?

    /// Сумма платежа
    var amountString: String

    /// Дата платежа
    var paymentDate: Date

    /// Комментарий: «Вернул половину»
    var comment: String?

    /// Дата создания записи
    var createdAt: Date = Date()

    /// Soft delete: nil = активен, Date = удалён
    var deletedAt: Date?

    // MARK: - Связи

    /// К какому долгу относится платёж
    @Relationship
    var debt: DebtModel?

    // MARK: - Вычисляемые свойства

    var amount: Decimal {
        get { Decimal(string: amountString) ?? 0 }
        set { amountString = "\(newValue)" }
    }

    // MARK: - Инициализатор

    init(
        amount: Decimal,
        paymentDate: Date,
        comment: String? = nil,
        debt: DebtModel? = nil,
        serverId: Int? = nil
    ) {
        self.amountString = "\(amount)"
        self.paymentDate = paymentDate
        self.comment = comment
        self.debt = debt
        self.serverId = serverId
        self.clientId = UUID().uuidString
        self.createdAt = Date()
    }
}
