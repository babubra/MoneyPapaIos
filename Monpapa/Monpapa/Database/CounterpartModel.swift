// MonPapa iOS — SwiftData модель: Counterpart (Контрагент)

import Foundation
import SwiftData

@Model
final class CounterpartModel {

    /// ID на сервере — nil если ещё не синхронизировано
    @Attribute(.unique)
    var serverId: Int?

    /// UUID для защиты от дубликатов при синхронизации
    @Attribute(.unique)
    var clientId: String?

    /// Имя: «Вася», «Тинькофф», «Мама»
    var name: String

    /// Emoji: «👤», «🏦»
    var icon: String?



    /// Дата создания
    var createdAt: Date = Date()

    /// Дата последнего обновления (для LWW sync)
    var updatedAt: Date = Date()

    /// Soft delete: nil = активен, Date = удалён
    var deletedAt: Date?

    // MARK: - Связи

    /// Долги с этим контрагентом
    @Relationship(deleteRule: .nullify, inverse: \DebtModel.counterpart)
    var debts: [DebtModel] = []

    // MARK: - Инициализатор

    init(
        name: String,
        icon: String? = nil,

        serverId: Int? = nil
    ) {
        self.name = name
        self.icon = icon

        self.serverId = serverId
        self.clientId = UUID().uuidString
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
