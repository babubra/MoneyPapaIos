// MonPapa iOS — Список транзакций (вкладка «Транзакции»)

import SwiftUI
import SwiftData

struct TransactionListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings

    @Query(filter: #Predicate<TransactionModel> { $0.deletedAt == nil },
           sort: \TransactionModel.transactionDate, order: .reverse)
    private var allTransactions: [TransactionModel]

    // MARK: - Фильтры

    /// nil = Все, .expense = Расходы, .income = Доходы
    @State private var selectedType: TransactionType? = nil

    /// Период (по умолчанию — текущий месяц)
    @State private var periodStart: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }()
    @State private var periodEnd: Date = Date.distantFuture

    // MARK: - UI State

    @State private var searchText = ""
    @State private var selectedTransaction: TransactionModel?
    @State private var selectedCategoryIds: Set<String> = []
    @State private var showPeriodPicker = false
    @State private var showCategoryFilter = false

    /// Пресет периода
    @State private var selectedPeriod: PeriodPreset = .month
    @State private var customStart: Date = Date()
    @State private var customEnd: Date = Date()

    // MARK: - Computed

    /// Отфильтрованные транзакции
    private var filteredTransactions: [TransactionModel] {
        allTransactions.filter { tx in
            // Период
            guard tx.transactionDate >= periodStart else { return false }
            if periodEnd != Date.distantFuture {
                guard tx.transactionDate <= periodEnd else { return false }
            }

            // Тип
            if let type = selectedType, tx.type != type {
                return false
            }

            // Категория
            if !selectedCategoryIds.isEmpty {
                guard let catId = tx.category?.clientId,
                      selectedCategoryIds.contains(catId) else { return false }
            }

            // Поиск
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchComment = tx.comment?.lowercased().contains(query) ?? false
                let matchRaw = tx.rawText?.lowercased().contains(query) ?? false
                let matchCategory = tx.category?.name.lowercased().contains(query) ?? false
                if !matchComment && !matchRaw && !matchCategory {
                    return false
                }
            }

            return true
        }
    }

    /// Группировка по дням
    private var groupedByDay: [(date: Date, transactions: [TransactionModel])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            calendar.startOfDay(for: tx.transactionDate)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (date: $0.key, transactions: $0.value) }
    }

    /// Итого по фильтру
    private var filteredTotal: Decimal {
        filteredTransactions.reduce(Decimal(0)) { sum, tx in
            tx.type == .income ? sum + tx.amount : sum - tx.amount
        }
    }

    private var filteredExpenseTotal: Decimal {
        filteredTransactions
            .filter { $0.type == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    private var filteredIncomeTotal: Decimal {
        filteredTransactions
            .filter { $0.type == .income }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: — Заголовок
                headerSection

                // MARK: — Сегмент типа
                typeSegment
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.bottom, MPSpacing.sm)

                // MARK: — Поиск
                searchBar
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.bottom, MPSpacing.sm)

                // MARK: — Список
                if filteredTransactions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                            ForEach(groupedByDay, id: \.date) { group in
                                Section {
                                    ForEach(group.transactions, id: \.id) { transaction in
                                        Button {
                                            selectedTransaction = transaction
                                        } label: {
                                            TransactionRow(transaction: transaction, showDate: false)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } header: {
                                    sectionHeader(for: group.date)
                                }
                            }

                            // Итого
                            if selectedType != nil {
                                totalFooter
                                    .padding(.top, MPSpacing.md)
                                    .padding(.bottom, MPSpacing.xl)
                            }
                        }
                        .padding(.horizontal, MPSpacing.md)
                        .padding(.bottom, MPSpacing.lg)
                    }
                }
            }
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
        }
        .sheet(isPresented: $showPeriodPicker) {
            PeriodPickerSheet(
                selectedPeriod: $selectedPeriod,
                customStart: $customStart,
                customEnd: $customEnd,
                onApply: { applyPeriod() }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCategoryFilter) {
            CategoryFilterView(
                selectedCategoryIds: $selectedCategoryIds,
                transactionType: selectedType
            )
            .presentationDetents([.large])
        }
    }

    // MARK: - Заголовок

    private var headerSection: some View {
        HStack {
            Text("Транзакции")
                .font(MPTypography.screenTitle)
                .foregroundColor(MPColors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.top, MPSpacing.sm)
        .padding(.bottom, MPSpacing.xs)
    }

    // MARK: - Сегмент типа

    private var typeSegment: some View {
        HStack(spacing: 4) {
            segmentButton(title: "Все", type: nil)
            segmentButton(title: "Расходы", type: .expense)
            segmentButton(title: "Доходы", type: .income)
        }
        .padding(4)
        .background(MPColors.cardBackground.opacity(0.6))
        .cornerRadius(MPCornerRadius.pill)
    }

    private func segmentButton(title: String, type: TransactionType?) -> some View {
        let isSelected = selectedType == type
        let color: Color = {
            switch type {
            case .expense: return MPColors.accentCoral
            case .income: return MPColors.accentGreen
            case nil: return MPColors.textSecondary
            }
        }()

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                selectedType = type
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .white : MPColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.xs)
                .background(
                    isSelected
                        ? AnyShapeStyle(color.opacity(0.85))
                        : AnyShapeStyle(.clear)
                )
                .cornerRadius(MPCornerRadius.pill - 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Поисковая строка

    private var searchBar: some View {
        HStack(spacing: MPSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(MPColors.textSecondary)

            TextField("Поиск транзакций...", text: $searchText)
                .font(MPTypography.body)
                .foregroundColor(MPColors.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(MPColors.textSecondary)
                }
            }

            // Кнопка периода
            Button {
                showPeriodPicker = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                    Text(selectedPeriod.shortTitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(selectedPeriod == .month ? MPColors.textSecondary : MPColors.accentCoral)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedPeriod == .month ? MPColors.cardBackground : MPColors.accentCoral.opacity(0.15))
                .cornerRadius(MPCornerRadius.sm)
            }

            // Кнопка категорий
            Button {
                showCategoryFilter = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14))
                    .foregroundColor(selectedCategoryIds.isEmpty ? MPColors.textSecondary : MPColors.accentCoral)
                    .frame(width: 28, height: 28)
                    .background(selectedCategoryIds.isEmpty ? MPColors.cardBackground : MPColors.accentCoral.opacity(0.15))
                    .cornerRadius(MPCornerRadius.sm)
            }
        }
        .padding(.horizontal, MPSpacing.sm)
        .padding(.vertical, MPSpacing.xs + 2)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }

    // MARK: - Section Header

    private func sectionHeader(for date: Date) -> some View {
        HStack {
            Text(formatSectionDate(date))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textSecondary)
            Spacer()
        }
        .padding(.vertical, MPSpacing.xs)
        .padding(.top, MPSpacing.xs)
        .background(MPColors.background)
    }

    // MARK: - Итого

    private var totalFooter: some View {
        HStack {
            Text("Итого")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.textSecondary)

            Spacer()

            if !settings.hideAmounts {
                let total = selectedType == .income ? filteredIncomeTotal : filteredExpenseTotal
                let sign = selectedType == .income ? "+" : "-"
                let color = selectedType == .income ? MPColors.accentGreen : MPColors.accentCoral

                Text("\(sign)\(formatAmount(total))")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            } else {
                Text("• • • ₽")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }

    // MARK: - Пустое состояние

    private var emptyState: some View {
        VStack(spacing: MPSpacing.md) {
            Spacer()
            Text("📋")
                .font(.system(size: 48))
            Text("Нет транзакций")
                .font(MPTypography.body)
                .foregroundColor(MPColors.textSecondary)
            if !searchText.isEmpty {
                Text("Попробуйте изменить поисковый запрос")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary.opacity(0.6))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Сегодня"
        } else if calendar.isDateInYesterday(date) {
            return "Вчера"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")

            if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
                formatter.dateFormat = "d MMMM"
            } else {
                formatter.dateFormat = "d MMMM yyyy"
            }

            return formatter.string(from: date)
        }
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: number) ?? "\(amount)") + " ₽"
    }

    // MARK: - Применение периода

    private func applyPeriod() {
        let cal = Calendar.current
        let now = Date()

        switch selectedPeriod {
        case .today:
            periodStart = cal.startOfDay(for: now)
            periodEnd = Date.distantFuture
        case .week:
            periodStart = cal.date(byAdding: .day, value: -7, to: now)!
            periodEnd = Date.distantFuture
        case .month:
            periodStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            periodEnd = Date.distantFuture
        case .prevMonth:
            let firstOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            periodStart = cal.date(byAdding: .month, value: -1, to: firstOfThisMonth)!
            periodEnd = firstOfThisMonth
        case .year:
            periodStart = cal.date(from: cal.dateComponents([.year], from: now))!
            periodEnd = Date.distantFuture
        case .prevYear:
            let firstOfThisYear = cal.date(from: cal.dateComponents([.year], from: now))!
            periodStart = cal.date(byAdding: .year, value: -1, to: firstOfThisYear)!
            periodEnd = firstOfThisYear
        case .custom:
            periodStart = cal.startOfDay(for: customStart)
            periodEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd))!
        }
    }
}

// MARK: - PeriodPreset

enum PeriodPreset: String, CaseIterable {
    case today = "today"
    case week = "week"
    case month = "month"
    case prevMonth = "prevMonth"
    case year = "year"
    case prevYear = "prevYear"
    case custom = "custom"

    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .week: return "Неделя"
        case .month: return "Текущий месяц"
        case .prevMonth: return "Прошлый месяц"
        case .year: return "Текущий год"
        case .prevYear: return "Прошлый год"
        case .custom: return "Произвольный"
        }
    }

    var shortTitle: String {
        switch self {
        case .today: return "День"
        case .week: return "Нед."
        case .month: return "Мес."
        case .prevMonth: return "Пр.мес."
        case .year: return "Год"
        case .prevYear: return "Пр.год"
        case .custom: return "Период"
        }
    }
}

// MARK: - PeriodPickerSheet

struct PeriodPickerSheet: View {
    @Binding var selectedPeriod: PeriodPreset
    @Binding var customStart: Date
    @Binding var customEnd: Date
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                VStack(spacing: MPSpacing.md) {
                    // Пресеты
                    VStack(spacing: 0) {
                        ForEach(PeriodPreset.allCases, id: \.self) { preset in
                            Button {
                                withAnimation {
                                    selectedPeriod = preset
                                }
                            } label: {
                                HStack {
                                    Text(preset.title)
                                        .font(MPTypography.body)
                                        .foregroundColor(MPColors.textPrimary)

                                    Spacer()

                                    if selectedPeriod == preset {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(MPColors.accentCoral)
                                    }
                                }
                                .padding(.horizontal, MPSpacing.md)
                                .padding(.vertical, MPSpacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if preset != .custom {
                                Divider().padding(.leading, MPSpacing.md)
                            }
                        }
                    }
                    .background(MPColors.cardBackground)
                    .cornerRadius(MPCornerRadius.lg)

                    // Произвольный период
                    if selectedPeriod == .custom {
                        VStack(spacing: 0) {
                            DatePicker("С", selection: $customStart, displayedComponents: .date)
                                .font(MPTypography.body)
                                .padding(.horizontal, MPSpacing.md)
                                .padding(.vertical, MPSpacing.xs)

                            Divider().padding(.leading, MPSpacing.md)

                            DatePicker("По", selection: $customEnd, displayedComponents: .date)
                                .font(MPTypography.body)
                                .padding(.horizontal, MPSpacing.md)
                                .padding(.vertical, MPSpacing.xs)
                        }
                        .background(MPColors.cardBackground)
                        .cornerRadius(MPCornerRadius.lg)
                    }

                    Spacer()
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.top, MPSpacing.sm)
            }
            .navigationTitle("Период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        onApply()
                        dismiss()
                    }
                    .foregroundColor(MPColors.accentCoral)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Тёмная") {
    TransactionListView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.dark)
}

#Preview("Светлая") {
    TransactionListView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.light)
}
