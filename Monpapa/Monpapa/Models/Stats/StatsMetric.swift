import Foundation

enum StatsMetric: String, CaseIterable, Identifiable {
    case expense
    case income
    case balance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense:
            return String(localized: "Расходы")
        case .income:
            return String(localized: "Доходы")
        case .balance:
            return String(localized: "Баланс")
        }
    }
}
