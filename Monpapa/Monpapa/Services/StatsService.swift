import Foundation

struct StatsService {
    static let uncategorizedId = "__uncategorized__"

    static func snapshot(
        transactions: [TransactionModel],
        period: StatsPeriod,
        metric: StatsMetric,
        currency: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> StatsSnapshot {
        let minDate = transactions.map(\.transactionDate).min()
        let interval = period.interval(now: now, calendar: calendar, minDate: minDate)
        let filtered = filteredTransactions(
            transactions: transactions,
            currency: currency,
            interval: interval
        )

        let totals = totals(for: filtered, metric: metric, interval: interval)
        let byCategory = topLevelCategoryStats(
            transactions: filtered,
            metric: metric
        )

        let timeline = timeline(
            transactions: filtered,
            metric: metric,
            component: period.timelineComponent(for: interval),
            interval: interval,
            calendar: calendar
        )

        let comparison = buildComparison(
            allTransactions: transactions,
            period: period,
            metric: metric,
            currency: currency,
            currentInterval: interval,
            currentValue: totals.total,
            calendar: calendar
        )

        return StatsSnapshot(
            period: period,
            metric: metric,
            currency: currency,
            interval: interval,
            totals: totals,
            byCategory: byCategory,
            timeline: timeline,
            comparison: comparison
        )
    }

    static func availableCurrencies(in transactions: [TransactionModel]) -> [String] {
        let currencies = Set(transactions.map(\.currency).filter { !$0.isEmpty })
        return currencies.sorted()
    }

    static func bestCurrency(
        in transactions: [TransactionModel],
        preferred: String,
        period: StatsPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let currencies = availableCurrencies(in: transactions)
        guard !currencies.isEmpty else { return preferred }

        let minDate = transactions.map(\.transactionDate).min()
        let interval = period.interval(now: now, calendar: calendar, minDate: minDate)

        let preferredCount = transactions.filter {
            $0.deletedAt == nil &&
            $0.currency == preferred &&
            interval.contains($0.transactionDate)
        }.count
        if preferredCount > 0 {
            return preferred
        }

        let countsByCurrency = Dictionary(grouping: transactions.filter {
            $0.deletedAt == nil && interval.contains($0.transactionDate)
        }, by: \.currency)
            .mapValues { $0.count }

        let best = countsByCurrency.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key

        return best ?? currencies.first ?? preferred
    }

    static func topLevelCategoryStats(
        transactions: [TransactionModel],
        metric: StatsMetric
    ) -> [CategoryStat] {
        let grouped = Dictionary(grouping: transactions) { transaction -> String in
            if let root = rootCategory(for: transaction.category) {
                return root.clientId ?? root.name
            }
            return uncategorizedId
        }

        let totalValue = metricTotal(for: transactions, metric: metric)
        let denominator = abs(decimalToDouble(totalValue))

        let stats = grouped.compactMap { key, txs -> CategoryStat? in
            let value = metricTotal(for: txs, metric: metric)
            guard value != 0 else { return nil }

            let share = denominator > 0
                ? abs(decimalToDouble(value)) / denominator
                : 0

            let category = key == uncategorizedId ? nil : rootCategory(for: txs.first?.category)
            return CategoryStat(
                id: key,
                category: category,
                total: value,
                count: txs.count,
                share: min(1, share)
            )
        }

        return stats.sorted { lhs, rhs in
            abs(decimalToDouble(lhs.total)) > abs(decimalToDouble(rhs.total))
        }
    }

    static func childCategoryStats(
        parent: CategoryModel,
        transactions: [TransactionModel],
        metric: StatsMetric
    ) -> [CategoryStat] {
        let parentId = parent.clientId
        let relevant = transactions.filter { tx in
            guard let category = tx.category else { return false }
            return rootCategory(for: category)?.clientId == parentId
        }

        let grouped = Dictionary(grouping: relevant) { tx -> String in
            if let category = tx.category {
                return category.clientId ?? category.name
            }
            return uncategorizedId
        }

        let denominator = abs(decimalToDouble(metricTotal(for: relevant, metric: metric)))

        let stats = grouped.compactMap { key, txs -> CategoryStat? in
            let value = metricTotal(for: txs, metric: metric)
            guard value != 0 else { return nil }
            let share = denominator > 0
                ? abs(decimalToDouble(value)) / denominator
                : 0
            return CategoryStat(
                id: key,
                category: txs.first?.category,
                total: value,
                count: txs.count,
                share: min(1, share)
            )
        }

        return stats.sorted {
            abs(decimalToDouble($0.total)) > abs(decimalToDouble($1.total))
        }
    }

    static func filteredTransactions(
        transactions: [TransactionModel],
        currency: String,
        interval: DateInterval
    ) -> [TransactionModel] {
        transactions.filter {
            $0.deletedAt == nil &&
            $0.currency == currency &&
            interval.contains($0.transactionDate)
        }
    }

    static func totals(
        for transactions: [TransactionModel],
        metric: StatsMetric,
        interval: DateInterval
    ) -> StatsTotals {
        let value = metricTotal(for: transactions, metric: metric)
        let days = max(1, Int(ceil(interval.duration / 86_400)))
        let average = value / Decimal(days)

        return StatsTotals(
            total: value,
            count: transactions.count,
            averagePerDay: average
        )
    }

    static func timeline(
        transactions: [TransactionModel],
        metric: StatsMetric,
        component: Calendar.Component,
        interval: DateInterval,
        calendar: Calendar
    ) -> [TimelinePoint] {
        let grouped = Dictionary(grouping: transactions) { tx in
            bucketStart(for: tx.transactionDate, component: component, calendar: calendar)
        }

        return grouped
            .map { date, txs in
                TimelinePoint(
                    id: date,
                    date: date,
                    total: metricTotal(for: txs, metric: metric)
                )
            }
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    static func rootCategory(for category: CategoryModel?) -> CategoryModel? {
        guard let category else { return nil }
        var current: CategoryModel = category

        while let parent = current.parent {
            current = parent
        }

        return current
    }

    static func metricTotal(for transactions: [TransactionModel], metric: StatsMetric) -> Decimal {
        switch metric {
        case .expense:
            return transactions
                .filter { $0.type == .expense }
                .reduce(0) { $0 + $1.amount }
        case .income:
            return transactions
                .filter { $0.type == .income }
                .reduce(0) { $0 + $1.amount }
        case .balance:
            return transactions.reduce(0) { partial, tx in
                tx.type == .income ? partial + tx.amount : partial - tx.amount
            }
        }
    }

    private static func buildComparison(
        allTransactions: [TransactionModel],
        period: StatsPeriod,
        metric: StatsMetric,
        currency: String,
        currentInterval: DateInterval,
        currentValue: Decimal,
        calendar: Calendar
    ) -> ComparisonStat? {
        guard let previousInterval = period.previousInterval(current: currentInterval, calendar: calendar) else {
            return nil
        }

        let previousTransactions = filteredTransactions(
            transactions: allTransactions,
            currency: currency,
            interval: previousInterval
        )
        let previousValue = metricTotal(for: previousTransactions, metric: metric)

        let previousDouble = decimalToDouble(previousValue)
        let currentDouble = decimalToDouble(currentValue)

        let percent: Double?
        if previousDouble == 0 {
            percent = nil
        } else {
            percent = ((currentDouble - previousDouble) / abs(previousDouble)) * 100
        }

        return ComparisonStat(
            current: currentValue,
            previous: previousValue,
            deltaPercent: percent
        )
    }

    private static func bucketStart(for date: Date, component: Calendar.Component, calendar: Calendar) -> Date {
        switch component {
        case .hour:
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: parts) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .weekOfYear:
            let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: parts) ?? date
        case .month:
            let parts = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: parts) ?? date
        default:
            return calendar.startOfDay(for: date)
        }
    }

    private static func decimalToDouble(_ value: Decimal) -> Double {
        Double(truncating: value as NSDecimalNumber)
    }
}
