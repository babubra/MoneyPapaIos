// MonPapa iOS — Список долгов (вкладка «Долги»)

import SwiftUI
import SwiftData

struct DebtListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings

    @Query(filter: #Predicate<DebtModel> { $0.deletedAt == nil },
           sort: \DebtModel.debtDate, order: .reverse)
    private var allDebts: [DebtModel]

    @Query(filter: #Predicate<CounterpartModel> { $0.deletedAt == nil },
           sort: \CounterpartModel.name)
    private var allCounterparts: [CounterpartModel]

    // MARK: - Фильтр

    /// nil = Все, .gave = Мне должны, .took = Я должен
    @State private var selectedDirection: DebtDirection? = nil

    // MARK: - UI State

    @State private var selectedDebt: DebtModel?
    @State private var showAddDebt = false
    @State private var showClosedDebts = false

    // MARK: - Computed

    /// Активные долги (не закрытые + фильтр направления)
    private var activeDebts: [DebtModel] {
        allDebts.filter { debt in
            guard !debt.isClosed else { return false }
            if let dir = selectedDirection, debt.direction != dir { return false }
            return true
        }
    }

    /// Закрытые долги
    private var closedDebts: [DebtModel] {
        allDebts.filter { $0.isClosed }
    }

    /// Общая сумма «Мне должны» (активные)
    private var totalGave: Decimal {
        allDebts
            .filter { $0.direction == .gave && !$0.isClosed }
            .reduce(Decimal(0)) { $0 + $1.remainingAmount }
    }

    /// Общая сумма «Я должен» (активные)
    private var totalTook: Decimal {
        allDebts
            .filter { $0.direction == .took && !$0.isClosed }
            .reduce(Decimal(0)) { $0 + $1.remainingAmount }
    }

    /// Количество активных «Мне должны»
    private var gaveCount: Int {
        allDebts.filter { $0.direction == .gave && !$0.isClosed }.count
    }

    /// Количество активных «Я должен»
    private var tookCount: Int {
        allDebts.filter { $0.direction == .took && !$0.isClosed }.count
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: — Заголовок
                headerSection

                // MARK: — Контент
                if allDebts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: MPSpacing.lg) {
                            // MARK: — Сводка
                            summaryCard

                            // MARK: — Сегмент фильтра
                            directionSegment

                            // MARK: — Активные долги
                            if activeDebts.isEmpty {
                                noActiveDebtsView
                            } else {
                                activeDebtsSection
                            }

                            // MARK: — Закрытые долги
                            if !closedDebts.isEmpty {
                                closedDebtsSection
                            }
                        }
                        .padding(.horizontal, MPSpacing.md)
                        .padding(.bottom, MPSpacing.xl)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddDebt) {
            AddDebtSheet()
        }
        .sheet(item: $selectedDebt) { debt in
            DebtDetailView(debt: debt)
        }
    }

    // MARK: - Заголовок

    private var headerSection: some View {
        HStack {
            Text("Долги")
                .font(MPTypography.screenTitle)
                .foregroundColor(MPColors.textPrimary)
            Spacer()
            Button {
                showAddDebt = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(MPColors.accentCoral)
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.top, MPSpacing.sm)
        .padding(.bottom, MPSpacing.xs)
    }

    // MARK: - Сводка

    private var summaryCard: some View {
        HStack(spacing: 0) {
            // Мне должны
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(MPColors.accentGreen)
                    Text("Мне должны")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }

                Text(settings.hideAmounts ? "•••••" : formattedAmount(totalGave))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.accentGreen)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(debtCountText(gaveCount))
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)

            // Разделитель
            Rectangle()
                .fill(MPColors.textSecondary.opacity(0.2))
                .frame(width: 0.5)
                .padding(.vertical, 8)

            // Я должен
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(MPColors.accentCoral)
                    Text("Я должен")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }

                Text(settings.hideAmounts ? "•••••" : formattedAmount(totalTook))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.accentCoral)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(debtCountText(tookCount))
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, MPSpacing.sm + 2)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Сегмент фильтра

    private var directionSegment: some View {
        HStack(spacing: 4) {
            segmentButton(titleKey: "Все", direction: nil)
            segmentButton(titleKey: "Мне должны", direction: .gave)
            segmentButton(titleKey: "Я должен", direction: .took)
        }
        .padding(4)
        .background(MPColors.cardBackground.opacity(0.6))
        .cornerRadius(MPCornerRadius.pill)
    }

    private func segmentButton(titleKey: LocalizedStringKey, direction: DebtDirection?) -> some View {
        let isSelected = selectedDirection == direction
        let color: Color = {
            switch direction {
            case .gave: return MPColors.accentGreen
            case .took: return MPColors.accentCoral
            case nil: return MPColors.textSecondary
            }
        }()

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                selectedDirection = direction
            }
        } label: {
            Text(titleKey)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
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

    // MARK: - Активные долги

    private var activeDebtsSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("Активные")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textSecondary)

            VStack(spacing: MPSpacing.xs) {
                ForEach(activeDebts, id: \.clientId) { debt in
                    Button {
                        selectedDebt = debt
                    } label: {
                        DebtCard(debt: debt)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Закрытые долги

    private var closedDebtsSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showClosedDebts.toggle()
                }
            } label: {
                HStack {
                    Text("Закрытые (\(closedDebts.count))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)

                    Spacer()

                    Image(systemName: showClosedDebts ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MPColors.textSecondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if showClosedDebts {
                VStack(spacing: MPSpacing.xs) {
                    ForEach(closedDebts, id: \.clientId) { debt in
                        Button {
                            selectedDebt = debt
                        } label: {
                            DebtCard(debt: debt)
                                .opacity(0.7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Пустые состояния

    private var emptyState: some View {
        VStack(spacing: MPSpacing.md) {
            Spacer()
            Text("🎉")
                .font(.system(size: 56))
            Text("Нет долгов")
                .font(MPTypography.screenTitle)
                .foregroundColor(MPColors.textPrimary)
            Text("У вас нет активных долгов.\nШикарно!")
                .font(MPTypography.body)
                .foregroundColor(MPColors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showAddDebt = true
            } label: {
                Text("Добавить долг")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, MPSpacing.lg)
                    .padding(.vertical, MPSpacing.sm)
                    .background(MPColors.accentCoral.opacity(0.85))
                    .cornerRadius(MPCornerRadius.pill)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noActiveDebtsView: some View {
        VStack(spacing: MPSpacing.sm) {
            Text("✨")
                .font(.system(size: 36))
            Text("Нет активных долгов")
                .font(MPTypography.body)
                .foregroundColor(MPColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MPSpacing.xl)
    }

    // MARK: - Helpers

    private func formattedAmount(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: number) ?? "\(amount)") + " ₽"
    }

    private func debtCountText(_ count: Int) -> String {
        switch count {
        case 0: return String(localized: "нет долгов")
        case 1: return String(localized: "1 долг")
        case 2...4: return String(localized: "\(count) долга")
        default: return String(localized: "\(count) долгов")
        }
    }
}

// MARK: - Preview

#Preview("Тёмная") {
    DebtListView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.dark)
}

#Preview("Светлая") {
    DebtListView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.light)
}
