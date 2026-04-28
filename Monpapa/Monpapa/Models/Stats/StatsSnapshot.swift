import Foundation

struct StatsTotals {
    let total: Decimal
    let count: Int
    let averagePerDay: Decimal
}

struct CategoryStat: Identifiable {
    let id: String
    let category: CategoryModel?
    let total: Decimal
    let count: Int
    let share: Double
}

struct TimelinePoint: Identifiable {
    let id: Date
    let date: Date
    let total: Decimal
}

struct ComparisonStat {
    let current: Decimal
    let previous: Decimal
    let deltaPercent: Double?
}

struct StatsSnapshot {
    let period: StatsPeriod
    let metric: StatsMetric
    let currency: String
    let interval: DateInterval
    let totals: StatsTotals
    let byCategory: [CategoryStat]
    let timeline: [TimelinePoint]
    let comparison: ComparisonStat?
}
