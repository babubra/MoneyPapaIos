import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @EnvironmentObject private var settings: AppSettings

    @Query(filter: #Predicate<TransactionModel> { $0.deletedAt == nil }, sort: \TransactionModel.transactionDate, order: .reverse)
    private var allTransactions: [TransactionModel]

    @State private var period: StatsPeriod = .month
    @State private var metric: StatsMetric = .expense
    @State private var currency: String = ""
    @State private var showCustomRange = false
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var selectedCategory: CategoryModel?

    private var resolvedCurrency: String {
        let preferred = currency.isEmpty ? settings.defaultCurrency : currency
        return StatsService.bestCurrency(
            in: allTransactions,
            preferred: preferred,
            period: period
        )
    }

    private var snapshot: StatsSnapshot {
        StatsService.snapshot(
            transactions: allTransactions,
            period: period,
            metric: metric,
            currency: resolvedCurrency
        )
    }

    private var availableCurrencies: [String] {
        StatsService.availableCurrencies(in: allTransactions)
    }

    private var intervalTransactions: [TransactionModel] {
        StatsService.filteredTransactions(
            transactions: allTransactions,
            currency: resolvedCurrency,
            interval: snapshot.interval
        )
    }

    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()

            if allTransactions.isEmpty {
                emptyHistoryState
            } else {
                ScrollView {
                    VStack(spacing: MPSpacing.md) {
                        headerSection
                        metricToggle
                        summaryCard
                        timelineChart

                        if let comparisonRows = topComparisonRows(), !comparisonRows.isEmpty {
                            comparisonSection(rows: comparisonRows)
                        }

                        categoriesSection
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.xl)
                }
            }
        }
        .sheet(isPresented: $showCustomRange) {
            StatsCustomRangeSheet(
                start: $customStart,
                end: $customEnd,
                onApply: {
                    let interval = makeCustomInterval(start: customStart, end: customEnd)
                    period = .custom(interval)
                }
            )
        }
        .sheet(item: $selectedCategory) { category in
            CategoryDetailStatsView(
                category: category,
                transactions: intervalTransactions,
                metric: metric,
                currency: resolvedCurrency,
                interval: snapshot.interval
            )
        }
        .onAppear {
            if currency.isEmpty {
                currency = StatsService.bestCurrency(
                    in: allTransactions,
                    preferred: settings.defaultCurrency,
                    period: period
                )
            }
        }
        .onChange(of: period) { _, _ in
            currency = StatsService.bestCurrency(
                in: allTransactions,
                preferred: currency.isEmpty ? settings.defaultCurrency : currency,
                period: period
            )
        }
    }

    // MARK: - Шапка (период + валюта)

    private var headerSection: some View {
        HStack(spacing: MPSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MPSpacing.xs) {
                    ForEach(StatsPeriod.allCases, id: \.id) { item in
                        periodButton(item)
                    }
                    if period.isCustom {
                        periodButton(period)
                    }
                }
            }

            Button {
                showCustomRange = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(period.isCustom ? .white : MPColors.textSecondary)
                    .frame(width: 36, height: 32)
                    .background(period.isCustom ? MPColors.accentBlue.opacity(0.9) : MPColors.cardBackground)
                    .cornerRadius(MPCornerRadius.pill)
            }
            .buttonStyle(.plain)

            if availableCurrencies.count > 1 {
                Menu {
                    ForEach(availableCurrencies, id: \.self) { item in
                        Button {
                            currency = item
                        } label: {
                            if item == resolvedCurrency {
                                Label(item, systemImage: "checkmark")
                            } else {
                                Text(item)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(resolvedCurrency)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(MPColors.textSecondary)
                    .padding(.horizontal, MPSpacing.sm)
                    .frame(height: 32)
                    .background(MPColors.cardBackground)
                    .cornerRadius(MPCornerRadius.pill)
                }
            }
        }
    }

    private func periodButton(_ item: StatsPeriod) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                period = item
            }
        } label: {
            Text(item.shortTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(period.id == item.id ? .white : MPColors.textSecondary)
                .padding(.horizontal, MPSpacing.sm)
                .frame(height: 32)
                .background(period.id == item.id ? MPColors.accentCoral.opacity(0.9) : MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.pill)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Метрика

    private var metricToggle: some View {
        HStack(spacing: 4) {
            ForEach(StatsMetric.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        metric = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(metric == item ? .white : MPColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(metricBackground(for: item))
                        .cornerRadius(MPCornerRadius.pill - 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(MPColors.cardBackground.opacity(0.75))
        .cornerRadius(MPCornerRadius.pill)
    }

    // MARK: - Итого

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: MPSpacing.xs) {
            HStack {
                Text(periodTitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)

                Spacer()

                if let comparison = snapshot.comparison, comparison.deltaPercent != nil {
                    comparisonPill(comparison)
                }
            }

            if settings.hideAmounts {
                Text("• • • \(resolvedCurrency)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
            } else {
                Text(formatAmount(snapshot.totals.total, currency: resolvedCurrency, withSign: metric == .balance))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(primaryAmountColor)
            }

            Text(summarySubtitle)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(MPColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    private var summarySubtitle: String {
        let count = snapshot.totals.count
        if settings.hideAmounts {
            return String(localized: "stats.summary.countOnly \(count)")
        }
        let avg = formatAmount(snapshot.totals.averagePerDay, currency: resolvedCurrency, withSign: false)
        return String(localized: "stats.summary.full \(count) \(avg)")
    }

    // MARK: - График

    private var timelineChart: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("Динамика")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)

            if snapshot.timeline.isEmpty {
                Text("Нет данных за выбранный период")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, MPSpacing.sm)
            } else {
                Chart(snapshot.timeline) { point in
                    BarMark(
                        x: .value("Дата", point.date),
                        y: .value("Сумма", decimalToDouble(point.total))
                    )
                    .foregroundStyle(chartColor)
                    .clipShape(RoundedRectangle(cornerRadius: MPCornerRadius.sm))
                }
                .frame(height: 180)
            }
        }
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Сравнение

    private func comparisonSection(rows: [ComparisonRow]) -> some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("Сравнение с прошлым периодом")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)

            ForEach(rows, id: \.title) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(MPColors.textPrimary)
                        Spacer()
                        if !settings.hideAmounts {
                            Text("\(formatCompact(row.current)) · \(formatCompact(row.previous))")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(MPColors.textSecondary)
                        }
                    }

                    HStack(spacing: 6) {
                        ProgressView(value: row.currentShare)
                            .tint(chartColor)
                        ProgressView(value: row.previousShare)
                            .tint(MPColors.textSecondary.opacity(0.4))
                    }
                }
            }
        }
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Топ категорий

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("Топ категорий")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)

            if snapshot.byCategory.isEmpty {
                Text("Нет данных по категориям")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary)
            } else {
                ForEach(snapshot.byCategory.prefix(10)) { item in
                    Button {
                        selectedCategory = item.category
                    } label: {
                        categoryRow(item)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.category == nil)
                }
            }
        }
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    private func categoryRow(_ item: CategoryStat) -> some View {
        HStack(spacing: MPSpacing.sm) {
            categoryIcon(item)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.category?.name ?? String(localized: "Без категории"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if settings.hideAmounts {
                        Text("• • •")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(MPColors.textSecondary)
                    } else {
                        Text(formatAmount(item.total, currency: resolvedCurrency, withSign: metric == .balance))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(MPColors.textPrimary)
                    }
                }

                HStack(spacing: 8) {
                    ProgressView(value: item.share)
                        .tint(chartColor)
                    Text("\(Int((item.share * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func categoryIcon(_ item: CategoryStat) -> some View {
        if let icon = item.category?.effectiveIcon, !icon.isEmpty {
            Text(icon)
                .font(.system(size: 22))
        } else {
            Circle()
                .fill(chartColor.opacity(0.15))
                .overlay(
                    Text(firstLetter(of: item.category?.name ?? "?"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(chartColor)
                )
        }
    }

    // MARK: - Пустое состояние

    private var emptyHistoryState: some View {
        VStack(spacing: MPSpacing.md) {
            Text("📊")
                .font(.system(size: 52))
            Text("Пока нет данных")
                .font(MPTypography.button)
                .foregroundColor(MPColors.textPrimary)
            Text("Добавьте транзакции, и здесь появится статистика")
                .font(MPTypography.caption)
                .foregroundColor(MPColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MPSpacing.lg)
        }
    }

    // MARK: - Вычисляемые свойства

    private var periodTitle: String {
        switch period {
        case .custom:
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yyyy"
            return "\(formatter.string(from: snapshot.interval.start)) – \(formatter.string(from: snapshot.interval.end.addingTimeInterval(-1)))"
        default:
            return period.shortTitle
        }
    }

    private var chartColor: Color {
        switch metric {
        case .expense: return MPColors.accentCoral
        case .income: return MPColors.accentGreen
        case .balance: return MPColors.accentBlue
        }
    }

    private var primaryAmountColor: Color {
        if metric == .balance && snapshot.totals.total < 0 {
            return MPColors.accentCoral
        }
        return chartColor
    }

    // MARK: - Helpers

    private func comparisonPill(_ comparison: ComparisonStat) -> some View {
        let delta = comparison.deltaPercent
        let isPositive = (delta ?? 0) >= 0

        // Для расходов рост = плохо (красный), для доходов/баланса рост = хорошо (зелёный)
        let deltaIsBad = metric == .expense ? isPositive : !isPositive
        let symbol = isPositive ? "arrow.up.right" : "arrow.down.right"
        let color = deltaIsBad ? MPColors.accentCoral : MPColors.accentGreen

        let text: String
        if let delta {
            text = String(format: "%@%.0f%%", isPositive ? "+" : "", delta)
        } else {
            text = "—"
        }

        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(MPCornerRadius.pill)
    }

    struct ComparisonRow {
        let title: String
        let current: Decimal
        let previous: Decimal
        let currentShare: Double
        let previousShare: Double
    }

    private func topComparisonRows() -> [ComparisonRow]? {
        guard let previousInterval = period.previousInterval(current: snapshot.interval) else {
            return nil
        }

        let previousTransactions = StatsService.filteredTransactions(
            transactions: allTransactions,
            currency: resolvedCurrency,
            interval: previousInterval
        )

        // Если в прошлом периоде вообще пусто — сравнивать бессмысленно
        guard !previousTransactions.isEmpty else { return nil }

        let previousStats = StatsService.topLevelCategoryStats(
            transactions: previousTransactions,
            metric: metric
        )

        let currentMap = Dictionary(uniqueKeysWithValues: snapshot.byCategory.map { ($0.id, $0) })
        let previousMap = Dictionary(uniqueKeysWithValues: previousStats.map { ($0.id, $0) })
        let allKeys = Set(currentMap.keys).union(previousMap.keys)

        let previousTotal = abs(decimalToDouble(StatsService.metricTotal(for: previousTransactions, metric: metric)))
        let currentTotal = abs(decimalToDouble(snapshot.totals.total))

        let rows = allKeys.compactMap { key -> ComparisonRow? in
            let current = currentMap[key]?.total ?? 0
            let previous = previousMap[key]?.total ?? 0
            if current == 0 && previous == 0 { return nil }

            let title = currentMap[key]?.category?.name
                ?? previousMap[key]?.category?.name
                ?? String(localized: "Без категории")

            let currentShare = currentTotal > 0
                ? min(1, abs(decimalToDouble(current)) / currentTotal)
                : 0
            let previousShare = previousTotal > 0
                ? min(1, abs(decimalToDouble(previous)) / previousTotal)
                : 0

            return ComparisonRow(
                title: title,
                current: current,
                previous: previous,
                currentShare: currentShare,
                previousShare: previousShare
            )
        }

        return rows
            .sorted { abs(decimalToDouble($0.current)) > abs(decimalToDouble($1.current)) }
            .prefix(5)
            .map { $0 }
    }

    private func metricBackground(for metric: StatsMetric) -> AnyShapeStyle {
        if self.metric == metric {
            switch metric {
            case .expense: return AnyShapeStyle(MPColors.accentCoral.opacity(0.9))
            case .income: return AnyShapeStyle(MPColors.accentGreen.opacity(0.9))
            case .balance: return AnyShapeStyle(MPColors.accentBlue.opacity(0.9))
            }
        }
        return AnyShapeStyle(.clear)
    }

    private func formatCompact(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = " "
        return formatter.string(from: number) ?? "0"
    }

    private func formatAmount(_ value: Decimal, currency: String, withSign: Bool = false) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = " "

        let raw = formatter.string(from: number) ?? "0"
        if withSign, value > 0 {
            return "+\(raw) \(currency)"
        }
        return "\(raw) \(currency)"
    }

    private func decimalToDouble(_ value: Decimal) -> Double {
        Double(truncating: value as NSDecimalNumber)
    }

    private func makeCustomInterval(start: Date, end: Date) -> DateInterval {
        let cal = Calendar.current
        let safeStart = cal.startOfDay(for: min(start, end))
        let safeEndBase = cal.startOfDay(for: max(start, end))
        let safeEnd = cal.date(byAdding: .day, value: 1, to: safeEndBase) ?? Date()
        return DateInterval(start: safeStart, end: safeEnd)
    }

    private func firstLetter(of text: String) -> String {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

}

private extension StatsPeriod {
    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

// MARK: - Custom range sheet

struct StatsCustomRangeSheet: View {
    @Binding var start: Date
    @Binding var end: Date
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                VStack(spacing: MPSpacing.md) {
                    VStack(spacing: 0) {
                        DatePicker("С", selection: $start, displayedComponents: .date)
                            .padding(.horizontal, MPSpacing.md)
                            .padding(.vertical, MPSpacing.sm)
                        Divider().padding(.leading, MPSpacing.md)
                        DatePicker("По", selection: $end, displayedComponents: .date)
                            .padding(.horizontal, MPSpacing.md)
                            .padding(.vertical, MPSpacing.sm)
                    }
                    .background(MPColors.cardBackground)
                    .cornerRadius(MPCornerRadius.lg)

                    Spacer()
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.top, MPSpacing.sm)
            }
            .navigationTitle("Свой период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Применить") {
                        onApply()
                        dismiss()
                    }
                    .foregroundColor(MPColors.accentCoral)
                }
            }
        }
    }
}

// MARK: - Category detail

struct CategoryDetailStatsView: View {
    let category: CategoryModel
    let transactions: [TransactionModel]
    let metric: StatsMetric
    let currency: String
    let interval: DateInterval

    @EnvironmentObject private var settings: AppSettings

    private var categoryTransactions: [TransactionModel] {
        transactions.filter { tx in
            guard let txCategory = tx.category else { return false }
            return StatsService.rootCategory(for: txCategory)?.clientId == category.clientId
        }
    }

    private var children: [CategoryStat] {
        StatsService.childCategoryStats(
            parent: category,
            transactions: categoryTransactions,
            metric: metric
        )
    }

    private var total: Decimal {
        StatsService.metricTotal(for: categoryTransactions, metric: metric)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.md) {
                        VStack(alignment: .leading, spacing: MPSpacing.sm) {
                            HStack {
                                Text(category.effectiveIcon ?? "📁")
                                Text(category.name)
                                    .font(MPTypography.button)
                                    .foregroundColor(MPColors.textPrimary)
                                Spacer()
                            }

                            if settings.hideAmounts {
                                Text("• • • \(currency)")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(MPColors.textPrimary)
                            } else {
                                Text(formatAmount(total))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(MPColors.textPrimary)
                            }
                        }
                        .padding(MPSpacing.md)
                        .background(MPColors.cardBackground)
                        .cornerRadius(MPCornerRadius.lg)

                        if !children.isEmpty {
                            VStack(alignment: .leading, spacing: MPSpacing.sm) {
                                Text("Подкатегории")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundColor(MPColors.textPrimary)

                                ForEach(children) { child in
                                    VStack(spacing: 6) {
                                        HStack {
                                            Text(child.category?.effectiveIcon ?? "📦")
                                            Text(child.category?.name ?? String(localized: "Без категории"))
                                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                                .foregroundColor(MPColors.textPrimary)
                                            Spacer()
                                            if settings.hideAmounts {
                                                Text("• • •")
                                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                    .foregroundColor(MPColors.textSecondary)
                                            } else {
                                                Text(formatAmount(child.total))
                                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                    .foregroundColor(MPColors.textSecondary)
                                            }
                                        }

                                        ProgressView(value: child.share)
                                            .tint(MPColors.accentCoral)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                            .padding(MPSpacing.md)
                            .background(MPColors.cardBackground)
                            .cornerRadius(MPCornerRadius.lg)
                        }

                        VStack(alignment: .leading, spacing: MPSpacing.sm) {
                            Text("Операции")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(MPColors.textPrimary)

                            if categoryTransactions.isEmpty {
                                Text("Нет транзакций за выбранный период")
                                    .font(MPTypography.caption)
                                    .foregroundColor(MPColors.textSecondary)
                            } else {
                                ForEach(categoryTransactions, id: \.id) { tx in
                                    TransactionRow(transaction: tx)
                                }
                            }
                        }
                        .padding(MPSpacing.md)
                        .background(MPColors.cardBackground)
                        .cornerRadius(MPCornerRadius.lg)
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.xl)
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func formatAmount(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = " "
        let raw = formatter.string(from: number) ?? "0"
        return "\(raw) \(currency)"
    }
}

#Preview("Stats") {
    StatsView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self,
            CategoryModel.self,
            CounterpartModel.self,
            DebtModel.self,
            DebtPaymentModel.self
        ], inMemory: true)
}
