// MonPapa iOS — Главный экран (Дашборд)

import SwiftUI
import SwiftData
import Combine

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    
    @Query(filter: #Predicate<TransactionModel> { $0.deletedAt == nil }, sort: \TransactionModel.transactionDate, order: .reverse)
    private var allTransactions: [TransactionModel]
    
    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil })
    private var allCategories: [CategoryModel]
    
    @State private var aiInputText = ""
    @State private var showSettings = false
    @State private var showAddTransaction = false
    @State private var manualTransactionType: TransactionType = .expense
    @State private var currentTime = Date()

    // AI-парсинг
    @State private var aiParseResult: AiParseResult?
    @State private var aiErrorMessage: String?
    @State private var showAiError = false
    
    /// Таймер для обновления часов каждую секунду
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    /// Последние 3 транзакции
    private var recentTransactions: [TransactionModel] {
        Array(allTransactions.prefix(3))
    }
    
    /// Категории для AI (конвертируем SwiftData → DTO)
    private var aiCategoryDTOs: [AICategoryDTO] {
        allCategories.compactMap { cat in
            guard let clientId = cat.clientId else { return nil }
            return AICategoryDTO(
                id: clientId,
                name: cat.name,
                type: cat.typeRaw,
                aiHint: cat.aiHint
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
    
    var body: some View {
        ZStack {
            // Декоративный фон с конфетти (как на экране логина)
            ConfettiBackground(particleCount: 20)
            
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: - Приветствие + настройки
                        headerSection
                        
                        // MARK: - Карточка баланса
                        balanceCard
                        
                        // MARK: - Последние операции
                        recentTransactionsSection
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.md)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
                
                // MARK: - Кнопки ручного добавления (всегда внизу)
                actionButtonsRow
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.bottom, MPSpacing.xs)
                
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
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(defaultType: manualTransactionType)
        }
        .sheet(item: $aiParseResult) { result in
            AddTransactionSheet(prefill: result)
        }
        .alert("Ошибка", isPresented: $showAiError) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(aiErrorMessage ?? "Неизвестная ошибка")
        }
    }

    // MARK: - AI Обработка результата

    private func handleAIResult(_ result: AiParseResult) {
        switch result.status {
        case .ok, .incomplete:
            aiParseResult = result
        case .rejected:
            aiErrorMessage = result.message ?? "Не удалось распознать транзакцию. Попробуйте иначе."
            showAiError = true
        }
    }
    
    // MARK: - Приветствие

    private var headerSection: some View {
        HStack {
            Text("Привет, Папа! 👋")
                .font(MPTypography.screenTitle)
                .foregroundColor(MPColors.textPrimary)
            
            Spacer()
            
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(MPColors.textSecondary)
            }
        }
    }
    
    // MARK: - Цвета текста карточки баланса
    
    private var cardTextPrimary: Color {
        colorScheme == .dark ? .white : Color(red: 0.25, green: 0.15, blue: 0.10)
    }
    
    private var cardTextSecondary: Color {
        colorScheme == .dark ? .white.opacity(0.8) : Color(red: 0.45, green: 0.35, blue: 0.28)
    }
    
    private var cardShadow: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .clear
    }
    
    // MARK: - Карточка баланса
    
    /// Форматированный день недели ("Вторник")
    private var formattedDayOfWeek: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: currentTime).capitalizedFirstLetter
    }
    
    /// Форматированное число и месяц ("1 апреля")
    private var formattedDayMonth: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: currentTime)
    }

    
    private var balanceCard: some View {
        HStack(alignment: .center, spacing: 0) {
            
            // MARK: — Левая треть: дата
            VStack(alignment: .leading, spacing: 2) {
                // День недели
                Text(formattedDayOfWeek)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(cardTextPrimary)
                    .lineLimit(1)
                
                // Число и месяц
                Text(formattedDayMonth)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(cardTextPrimary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            
            // Вертикальный разделитель
            // Отступ слева = MPSpacing.md = отступу карточки от края экрана
            Rectangle()
                .fill(cardTextSecondary.opacity(0.2))
                .frame(width: 0.5)
                .padding(.vertical, 6)
                .padding(.leading, MPSpacing.md)
                .padding(.trailing, MPSpacing.md)
            
            // MARK: — Правые две трети: баланс + доходы/расходы
            VStack(alignment: .center, spacing: 4) {
                Text("Баланс")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(cardTextSecondary)
                
                Text(settings.hideAmounts ? "••••••" : formatAmount(monthlyBalance))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(cardTextPrimary)
                    .shadow(color: cardShadow, radius: 4, x: 0, y: 2)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                
                HStack(spacing: MPSpacing.md) {
                    VStack(spacing: 1) {
                        Text(settings.hideAmounts ? "•••" : "+\(formatAmount(monthlyIncome))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(colorScheme == .dark
                                ? Color(red: 0.6, green: 1.0, blue: 0.6)
                                : Color(red: 0.2, green: 0.7, blue: 0.2))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("доходы")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundColor(cardTextSecondary)
                    }
                    
                    VStack(spacing: 1) {
                        Text(settings.hideAmounts ? "•••" : "-\(formatAmount(monthlyExpenses))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(colorScheme == .dark
                                ? Color(red: 1.0, green: 0.6, blue: 0.5)
                                : Color(red: 0.9, green: 0.3, blue: 0.2))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("расходы")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundColor(cardTextSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm + 2)
        .background(
            ZStack {
                HStack(spacing: 0) {
                    if colorScheme == .dark {
                        Color(red: 0.55, green: 0.25, blue: 0.15).opacity(0.4)
                        Color(red: 0.35, green: 0.18, blue: 0.12).opacity(0.5)
                        Color(red: 0.15, green: 0.30, blue: 0.35).opacity(0.4)
                    } else {
                        MPColors.accentYellow.opacity(0.25)
                        MPColors.accentCoral.opacity(0.15)
                        MPColors.accentBlue.opacity(0.2)
                    }
                }
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        )
        .cornerRadius(MPCornerRadius.lg)
        .clipped()
        .onReceive(clockTimer) { time in
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTime = time
            }
        }
    }
    
    // MARK: - Последние операции
    
    private var recentTransactionsSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("Последние операции")
                .font(MPTypography.button)
                .foregroundColor(MPColors.textPrimary)
            
            if recentTransactions.isEmpty {
                // Пустое состояние
                VStack(spacing: MPSpacing.sm) {
                    Text("🏠")
                        .font(.system(size: 40))
                    Text("Пока нет транзакций")
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textSecondary)
                    Text("Введите первую транзакцию\nв поле ниже")
                        .font(MPTypography.caption)
                        .foregroundColor(MPColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.xl)
            } else {
                VStack(spacing: MPSpacing.xs) {
                    ForEach(recentTransactions, id: \.clientId) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
                
                // Ссылка «Все транзакции» удалена по дизайну
            }
        }
    }
    
    // MARK: - Кнопки ручного добавления
    
    private var actionButtonsRow: some View {
        HStack(spacing: MPSpacing.sm) {
            actionPillButton(title: "Долг", prefix: "🤝", color: MPColors.accentBlue) {
                // TODO: Открытие экрана создания долга
            }
            
            actionPillButton(title: "Доход", prefix: "➕", color: MPColors.accentGreen) {
                manualTransactionType = .income
                showAddTransaction = true
            }
            
            actionPillButton(title: "Расход", prefix: "➖", color: MPColors.accentCoral) {
                manualTransactionType = .expense
                showAddTransaction = true
            }
        }
    }
    
    private func actionPillButton(title: String, prefix: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(prefix)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: MPCornerRadius.pill)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.9), color.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    // Стеклянный блик
                    RoundedRectangle(cornerRadius: MPCornerRadius.pill)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .shadow(color: color.opacity(0.4), radius: 8, x: 0, y: 3)
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

// MARK: - String Extension

extension String {
    /// Капитализация первой буквы строки ("вторник, 1 апреля" → "Вторник, 1 апреля")
    var capitalizedFirstLetter: String {
        guard let first = self.first else { return self }
        return first.uppercased() + self.dropFirst()
    }
}
