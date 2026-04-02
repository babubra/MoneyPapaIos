// MonPapa iOS — SwiftData модель: Counterpart (Контрагент)

import Foundation
import SwiftData

@Model
final class CounterpartModel {

    /// ID на сервере — nil если ещё не синхронизировано
    @Attribute(.unique)
    var serverId: Int?

    /// Имя: «Вася», «Тинькофф», «Мама»
    var name: String

    /// Emoji: «👤», «🏦»
    var icon: String?

    /// Подсказка для AI: «это мой коллега по работе»
    var aiHint: String?

    /// Дата создания
    var createdAt: Date

    // MARK: - Связи

    /// Долги с этим контрагентом
    @Relationship(deleteRule: .nullify, inverse: \DebtModel.counterpart)
    var debts: [DebtModel] = []

    // MARK: - Инициализатор

    init(
        name: String,
        icon: String? = nil,
        aiHint: String? = nil,
        serverId: Int? = nil
    ) {
        self.name = name
        self.icon = icon
        self.aiHint = aiHint
        self.serverId = serverId
        self.createdAt = Date()
    }
}
