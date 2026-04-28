// MonPapa iOS — Главный экран (Дашборд)

import SwiftUI
import SwiftData
import Combine
import os

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    
    @Query(filter: #Predicate<TransactionModel> { $0.deletedAt == nil }, sort: \TransactionModel.createdAt, order: .reverse)
    private var allTransactions: [TransactionModel]
    
    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil })
    private var allCategories: [CategoryModel]

    @Query(filter: #Predicate<DebtModel> { $0.deletedAt == nil && $0.isClosed == false },
           sort: \DebtModel.debtDate, order: .reverse)
    private var activeDebts: [DebtModel]
    
    @State private var aiInputText = ""
    @State private var showSettings = false
    @State private var showAddDebt = false
    
    struct ManualTransactionParams: Identifiable {
        let id = UUID()
        let type: TransactionType
    }
    @State private var manualTransactionParams: ManualTransactionParams?

    // AI-парсинг
    @State private var aiParseResult: AiParseResult?
    @State private var aiDebtPrefill: AiParseResult?
    @State private var aiErrorMessage: String?
    @State private var showAiError = false
    @State private var selectedTransaction: TransactionModel?

    /// Для AI-платежей по долгу
    struct DebtPaymentTarget: Identifiable {
        let id = UUID()
        let debt: DebtModel
        let prefillAmount: Double?
        let prefillComment: String?
    }
    @State private var debtPaymentTarget: DebtPaymentTarget?

    /// Для выбора долга при нескольких совпадениях
    @State private var debtPickerDebts: [DebtModel] = []
    @State private var debtPickerAmount: Double?
    @State private var debtPickerComment: String?
    @State private var showDebtPicker = false
    
    // Анимация пустого состояния
    @State private var arrowBounce = false
    
    /// Последние 4 транзакции (по дате создания)
    private var recentTransactions: [TransactionModel] {
        Array(allTransactions.prefix(4))
    }
    
    /// Категории для AI (конвертируем SwiftData → DTO)
    private var aiCategoryDTOs: [AICategoryDTO] {
        allCategories.compactMap { cat in
            guard let clientId = cat.clientId else { return nil }
            return AICategoryDTO(
                id: clientId,
                name: cat.name,
                type: cat.typeRaw
            )
        }
    }
    
    /// Общий доход за текущий месяц
    private var monthlyIncome: Decimal {
        currentMonthTransactions
            .filter { $0.type == .income }
            .reduce(0) { $0 + $1.amount }
    }
    
    /// Общие расходы за текущий месяц
    private var monthlyExpenses: Decimal {
        currentMonthTransactions
            .filter { $0.type == .expense }
            .reduce(0) { $0 + $1.amount }
    }
    
    /// Баланс за текущий месяц
    private var monthlyBalance: Decimal {
        monthlyIncome - monthlyExpenses
    }
    
    /// Транзакции текущего месяца
    private var currentMonthTransactions: [TransactionModel] {
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        return allTransactions.filter { $0.transactionDate >= startOfMonth }
    }
    
    // MARK: - Динамическое приветствие по времени суток
    
    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12:
            return String(localized: "Доброе утро ☀️")
        case 12..<18:
            return String(localized: "Добрый день 👋")
        case 18..<23:
            return String(localized: "Добрый вечер 🌙")
        default:
            return String(localized: "Не спится? 🦉")
        }
    }
    
    var body: some View {
        ZStack {
            // Декоративный фон с конфетти (как на экране логина)
            ConfettiBackground(particleCount: 20)
            
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: MPSpacing.xl) {
                        // MARK: - Приветствие + настройки
                        headerSection
                        
                        // MARK: - Карточка баланса
                        BalanceCardView(
                            monthlyBalance: monthlyBalance,
                            monthlyIncome: monthlyIncome,
                            monthlyExpenses: monthlyExpenses
                        )
                        
                        // MARK: - Активные долги
                        ActiveDebtsSummary(
                            debts: activeDebts,
                            onTapDebt: { _ in
                                // Переход в таб «Долги» — пока просто показываем все
                            },
                            onShowAll: {
                                // Переход в таб «Долги»
                            }
                        )
                        
                        // MARK: - Последние операции
                        recentTransactionsSection
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.md)
                    .padding(.bottom, MPSpacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
                
                // MARK: - Кнопки ручного добавления (всегда внизу)
                actionButtonsRow
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.lg)
                    .padding(.bottom, MPSpacing.sm)
                
                // MARK: - AI Input Bar
                AIInputBar(
                    text: $aiInputText,
                    categories: aiCategoryDTOs,
                    onParseResult: { result in
                        handleAIResult(result)
                    },
                    onVoiceResult: { result in
                        handleAIResult(result)
                    },
                    onError: { error in
                        aiErrorMessage = error
                        showAiError = true
                    }
                )
                .padding(.bottom, MPSpacing.sm)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $manualTransactionParams) { params in
            AddTransactionSheet(defaultType: params.type)
        }
        .sheet(item: $aiParseResult) { result in
            AddTransactionSheet(prefill: result)
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
        }
        .sheet(isPresented: $showAddDebt) {
            AddDebtSheet()
        }
        .sheet(item: $aiDebtPrefill) { result in
            AddDebtSheet(prefill: result)
        }
        .sheet(item: $debtPaymentTarget) { target in
            AddPaymentSheet(debt: target.debt, prefillAmount: target.prefillAmount, prefillComment: target.prefillComment)
        }
        .alert("Ошибка", isPresented: $showAiError) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(aiErrorMessage ?? String(localized: "error.unknownError"))
        }
        .sheet(isPresented: $showDebtPicker) {
            DebtPickerSheet(
                debts: debtPickerDebts,
                prefillAmount: debtPickerAmount
            ) { selectedDebt in
                debtPaymentTarget = DebtPaymentTarget(
                    debt: selectedDebt,
                    prefillAmount: debtPickerAmount,
                    prefillComment: debtPickerComment
                )
            }
            .presentationDetents([.medium])
        }
    }
    
    // MARK: - Приветствие
    
    private var headerSection: some View {
        HStack {
            Text(greetingText)
                .font(MPTypography.screenTitle)
                .foregroundColor(MPColors.textPrimary)
            
            Spacer()
            
            HStack(spacing: 20) {
                // Кнопка скрытия сумм
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.hideAmounts.toggle()
                    }
                } label: {
                    Image(systemName: settings.hideAmounts ? "eye.slash" : "eye")
                        .font(.system(size: 22))
                        .foregroundColor(MPColors.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                
                // Настройки
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22))
                        .foregroundColor(MPColors.textSecondary)
                }
            }
        }
    }
    
    // MARK: - Последние операции
    
    private var recentTransactionsSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text(String(localized: "Последние операции"))
                .font(MPTypography.button)
                .foregroundColor(MPColors.textPrimary)
            
            if recentTransactions.isEmpty {
                // Улучшенное пустое состояние с CTA
                emptyStateView
            } else {
                VStack(spacing: MPSpacing.xs) {
                    ForEach(recentTransactions, id: \.clientId) { transaction in
                        Button {
                            selectedTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - Пустое состояние (CTA)
    
    private var emptyStateView: some View {
        VStack(spacing: MPSpacing.md) {
            // Иконка микрофона с градиентом
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                MPColors.accentCoral.opacity(colorScheme == .dark ? 0.2 : 0.12),
                                MPColors.accentYellow.opacity(colorScheme == .dark ? 0.12 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                
                Image(systemName: "mic.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MPColors.accentCoral, MPColors.accentYellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            VStack(spacing: MPSpacing.xs) {
                Text(String(localized: "Пока нет транзакций"))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
                
                Text(String(localized: "Скажите голосом: «Купил кофе за 200 руб» — или введите текст в поле ниже"))
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            
            // Пульсирующая стрелка вниз
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(MPColors.accentCoral.opacity(0.6))
                .offset(y: arrowBounce ? 6 : 0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: arrowBounce
                )
                .onAppear { arrowBounce = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MPSpacing.xl)
    }
    
    // MARK: - Кнопки ручного добавления
    
    private var actionButtonsRow: some View {
        HStack(spacing: MPSpacing.sm) {
            actionPillButton(
                title: String(localized: "Долг"),
                icon: "arrow.left.arrow.right",
                color: MPColors.accentBlue
            ) {
                showAddDebt = true
            }
            
            actionPillButton(
                title: String(localized: "Доход"),
                icon: "plus.circle.fill",
                color: MPColors.accentGreen
            ) {
                manualTransactionParams = ManualTransactionParams(type: .income)
            }
            
            actionPillButton(
                title: String(localized: "Расход"),
                icon: "minus.circle.fill",
                color: MPColors.accentCoral
            ) {
                manualTransactionParams = ManualTransactionParams(type: .expense)
            }
        }
    }
    
    private func actionPillButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.85))
            .cornerRadius(MPCornerRadius.pill)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Форматирование
    
    private func formatAmount(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: number) ?? "\(amount)") + " ₽"
    }
}

// MARK: - AI Обработка результата

extension DashboardView {
    
    func handleAIResult(_ result: AiParseResult) {
        MPLog.dashboard.info("🎯 handleAIResult: status=\(String(describing: result.status), privacy: .public) type=\(result.type ?? "nil", privacy: .public) amount=\(result.amount ?? 0) cp=\(result.counterpartName ?? "nil", privacy: .public) flow=\(result.paymentFlow ?? "nil", privacy: .public)")
        switch result.status {
        case .ok, .incomplete:
            if let type = result.type {
                switch type {
                case "debt_payment":
                    MPLog.dashboard.info("🎯 branch → debt_payment")
                    // Платёж по существующему долгу — ищем долг по контрагенту
                    handleDebtPayment(result)
                case "debt_give", "debt_take":
                    MPLog.dashboard.info("🎯 branch → new debt (\(type, privacy: .public)) → AddDebtSheet")
                    // Новый долг → AddDebtSheet
                    aiDebtPrefill = result
                default:
                    MPLog.dashboard.info("🎯 branch → transaction (\(type, privacy: .public)) → AddTransactionSheet")
                    // Обычная транзакция
                    aiParseResult = result
                }
            } else {
                MPLog.dashboard.notice("🎯 branch → no type, fallback to AddTransactionSheet")
                aiParseResult = result
            }
        case .rejected:
            MPLog.dashboard.notice("🎯 branch → rejected: \(result.message ?? "nil", privacy: .public)")
            aiErrorMessage = result.message ?? String(localized: "error.parseRejected")
            showAiError = true
        }
    }

    /// Обработка debt_payment: поиск долга по контрагенту + направлению → AddPaymentSheet
    func handleDebtPayment(_ result: AiParseResult) {
        guard let cpName = result.counterpartName, !cpName.isEmpty else {
            MPLog.dashboard.error("💸 handleDebtPayment: counterpart отсутствует → error")
            aiErrorMessage = String(localized: "error.noCounterpart")
            showAiError = true
            return
        }

        MPLog.dashboard.info("💸 handleDebtPayment: cp=\"\(cpName, privacy: .public)\" cpId=\(result.counterpartId ?? "nil", privacy: .public) flow=\(result.paymentFlow ?? "nil", privacy: .public) activeDebts=\(activeDebts.count)")

        // Поиск долгов по контрагенту (с учётом перестановки слов в имени)
        var matchingDebts: [DebtModel]
        var searchStage: String
        if let cpId = result.counterpartId {
            matchingDebts = activeDebts.filter { $0.counterpart?.clientId == cpId }
            searchStage = "byId"
        } else {
            // 1. Точное совпадение (регистронезависимое)
            matchingDebts = activeDebts.filter {
                $0.counterpart?.name.localizedCaseInsensitiveCompare(cpName) == .orderedSame
            }
            searchStage = "exactName"

            // 2. Если точного нет — пробуем перестановку слов
            // «Иванов Степан» ↔ «Степан Иванов»
            if matchingDebts.isEmpty {
                let queryWords = Set(cpName.lowercased().split(separator: " ").map(String.init))
                matchingDebts = activeDebts.filter { debt in
                    guard let name = debt.counterpart?.name else { return false }
                    let debtWords = Set(name.lowercased().split(separator: " ").map(String.init))
                    return debtWords == queryWords
                }
                if !matchingDebts.isEmpty { searchStage = "wordSetEqual" }
            }

            // 3. Если и так нет — частичное совпадение (все слова запроса содержатся в имени)
            if matchingDebts.isEmpty {
                let queryWords = cpName.lowercased().split(separator: " ").map(String.init)
                matchingDebts = activeDebts.filter { debt in
                    guard let name = debt.counterpart?.name.lowercased() else { return false }
                    return queryWords.allSatisfy { name.contains($0) }
                }
                if !matchingDebts.isEmpty { searchStage = "partialContains" }
            }
        }

        let matchNames = matchingDebts.compactMap { $0.counterpart?.name }.joined(separator: ", ")
        MPLog.dashboard.info("💸 поиск долга stage=\(searchStage, privacy: .public) found=\(matchingDebts.count) [\(matchNames, privacy: .public)]")

        // Фильтрация по направлению (payment_flow)
        // inbound = мне возвращают → я давал (gave)
        // outbound = я возвращаю → я брал (took)
        if let flow = result.paymentFlow {
            let expectedDirection: DebtDirection = flow == "inbound" ? .gave : .took
            let filtered = matchingDebts.filter { $0.direction == expectedDirection }
            MPLog.dashboard.info("💸 фильтр по flow=\(flow, privacy: .public) (dir=\(expectedDirection.rawValue, privacy: .public)): \(matchingDebts.count) → \(filtered.count)")
            if !filtered.isEmpty {
                matchingDebts = filtered
            } else {
                MPLog.dashboard.notice("💸 ⚠️ фильтр пуст — оставляем все \(matchingDebts.count) долгов (лучше чем ничего)")
            }
            // Если фильтр пустой — показываем все (лучше чем ничего)
        }

        if matchingDebts.count == 1 {
            MPLog.dashboard.info("💸 → AddPaymentSheet (single match: \(matchingDebts[0].counterpart?.name ?? "nil", privacy: .public))")
            debtPaymentTarget = DebtPaymentTarget(
                debt: matchingDebts[0],
                prefillAmount: result.amount,
                prefillComment: result.rawText
            )
        } else if matchingDebts.count > 1 {
            MPLog.dashboard.info("💸 → DebtPicker (\(matchingDebts.count) matches)")
            debtPickerDebts = matchingDebts
            debtPickerAmount = result.amount
            debtPickerComment = result.rawText
            showDebtPicker = true
        } else {
            MPLog.dashboard.notice("💸 → error: noActiveDebts для \"\(cpName, privacy: .public)\"")
            aiErrorMessage = String(localized: "error.noActiveDebts \(cpName)")
            showAiError = true
        }
    }
}

// MARK: - Preview

#Preview("Дашборд — светлая") {
    DashboardView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self,
            CategoryModel.self,
            CounterpartModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ], inMemory: true)
        .preferredColorScheme(.light)
}

#Preview("Дашборд — тёмная") {
    DashboardView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self,
            CategoryModel.self,
            CounterpartModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ], inMemory: true)
        .preferredColorScheme(.dark)
}
