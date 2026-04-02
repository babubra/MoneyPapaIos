// MonPapa iOS — Форма ручного добавления транзакции (Sheet)

import SwiftUI
import SwiftData

struct AddTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    
    // MARK: - Поля формы
    
    @State private var transactionType: TransactionType = .expense
    @State private var amountText = ""
    @State private var transactionDate = Date()
    @State private var selectedExpenseCategory: CategoryModel?
    @State private var selectedIncomeCategory: CategoryModel?
    @State private var comment = ""
    
    /// Текущая категория в зависимости от выбранного типа
    private var selectedCategory: CategoryModel? {
        switch transactionType {
        case .expense: selectedExpenseCategory
        case .income: selectedIncomeCategory
        }
    }
    
    /// Binding для CategoryPickerView
    private var categoryBinding: Binding<CategoryModel?> {
        switch transactionType {
        case .expense:
            $selectedExpenseCategory
        case .income:
            $selectedIncomeCategory
        }
    }
    
    // MARK: - UI State
    
    @State private var showCategoryPicker = false
    @FocusState private var focusedField: Field?
    
    private enum Field {
        case amount, comment
    }
    
    // MARK: - Валидация
    
    private var amountValue: Decimal {
        let cleaned = amountText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }
    
    private var canSave: Bool {
        amountValue > 0
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: — Сегмент Расход / Доход
                        typeSegment
                        
                        // MARK: — Крупный ввод суммы
                        amountInput
                        
                        // MARK: — Дата + Категория + Комментарий (карточка)
                        formCard
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationTitle("Новая операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { saveTransaction() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(canSave ? MPColors.accentCoral : MPColors.textSecondary)
                        .disabled(!canSave)
                }
            }
        }
    }
    
    // MARK: - Сегмент типа (Liquid Glass Glow)
    
    /// Цвет активного сегмента в зависимости от типа
    private var segmentColor: Color {
        transactionType == .expense
            ? MPColors.accentCoral
            : MPColors.accentGreen
    }
    
    private var typeSegment: some View {
        HStack(spacing: 4) {
            segmentButton(title: "Расход", type: .expense, color: MPColors.accentCoral)
            segmentButton(title: "Доход", type: .income, color: MPColors.accentGreen)
        }
        .padding(4)
        .background(
            MPColors.cardBackground.opacity(0.6)
        )
        .cornerRadius(MPCornerRadius.pill)
        .padding(.horizontal, MPSpacing.xs)
    }
    
    private func segmentButton(title: String, type: TransactionType, color: Color) -> some View {
        let isSelected = transactionType == type
        
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                transactionType = type
            }
        } label: {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .white : MPColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm)
                .background(
                    ZStack {
                        if isSelected {
                            // Градиентная подложка
                            RoundedRectangle(cornerRadius: MPCornerRadius.pill - 2)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            color.opacity(0.9),
                                            color.opacity(0.7),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            
                            // Стеклянный блик сверху
                            RoundedRectangle(cornerRadius: MPCornerRadius.pill - 2)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.3),
                                            .clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        }
                    }
                )
                .cornerRadius(MPCornerRadius.pill - 2)
                .contentShape(Rectangle())
                // Glow-свечение вокруг активного сегмента
                .shadow(
                    color: isSelected ? color.opacity(0.5) : .clear,
                    radius: isSelected ? 12 : 0,
                    x: 0, y: 0
                )
                .shadow(
                    color: isSelected ? color.opacity(0.3) : .clear,
                    radius: isSelected ? 20 : 0,
                    x: 0, y: 4
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Крупный ввод суммы
    
    private var amountInput: some View {
        VStack(spacing: MPSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("0", text: $amountText)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused($focusedField, equals: .amount)
                    .minimumScaleFactor(0.5)
                    .onChange(of: amountText) { _, newValue in
                        let formatted = formatAmountText(newValue)
                        if formatted != newValue {
                            amountText = formatted
                        }
                    }
                
                Text(currencySymbol)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MPSpacing.lg)
        }
        .onAppear {
            focusedField = .amount
        }
    }
    
    /// Форматирует строку суммы: добавляет пробелы как разделители тысяч
    /// Пример: "10000" → "10 000", "1234567.89" → "1 234 567.89"
    private func formatAmountText(_ input: String) -> String {
        // Разрешённые символы: цифры, запятая и точка
        let allowedChars = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".,"))
        let filtered = input.unicodeScalars.filter { allowedChars.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: ",", with: ".")
        
        // Разделяем целую и дробную части
        let parts = clean.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.isEmpty ? "" : String(parts[0])
        
        // Форматируем целую часть — вставляем пробелы каждые 3 цифры справа
        var formattedInt = ""
        for (index, char) in intPart.reversed().enumerated() {
            if index > 0, index % 3 == 0 {
                formattedInt.insert(" ", at: formattedInt.startIndex)
            }
            formattedInt.insert(char, at: formattedInt.startIndex)
        }
        
        // Если была точка (дробная часть)
        if parts.count > 1 {
            let fracPart = String(parts[1])
            // Возвращаем запятую обратно для отображения
            return formattedInt + "," + fracPart
        }
        
        // Если input заканчивался на запятую/точку — сохраняем её
        if clean.hasSuffix(".") {
            return formattedInt + ","
        }
        
        return formattedInt
    }
    
    // MARK: - Карточка формы (Дата + Категория + Комментарий)
    
    private var formCard: some View {
        VStack(spacing: 0) {
            // 📅 Дата
            formRow(icon: "📅", label: "Дата") {
                DatePicker("", selection: $transactionDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(MPColors.accentCoral)
            }
            
            Divider()
                .padding(.leading, 52)

            // 🏷️ Категория
            Button {
                showCategoryPicker = true
            } label: {
                HStack(spacing: MPSpacing.sm) {
                    if let cat = selectedCategory {
                        // Выбрана: показываем иконку категории + название
                        if let icon = cat.effectiveIcon {
                            Text(icon)
                                .font(.system(size: 20))
                                .frame(width: 28)
                        }
                        
                        Text(cat.name)
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                            .lineLimit(1)
                    } else {
                        // Не выбрана: показываем лейбл + placeholder
                        Text("🏷️")
                            .font(.system(size: 20))
                            .frame(width: 28)
                        
                        Text("Категория")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                    }
                    
                    Spacer()
                    
                    if selectedCategory == nil {
                        Text("Выберите")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textSecondary)
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MPColors.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.vertical, MPSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Divider()
                .padding(.leading, 52)
            
            // 💬 Комментарий (лейбл + многострочное поле)
            VStack(alignment: .leading, spacing: 0) {
                formRow(icon: "💬", label: "Комментарий") {
                    EmptyView()
                }
                
                ZStack(alignment: .topLeading) {
                    // Плейсхолдер
                    if comment.isEmpty {
                        Text("Обед в кафе, продукты...")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textSecondary.opacity(0.5))
                            .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm)
                            .padding(.vertical, MPSpacing.xxs + 1)
                            .allowsHitTesting(false)
                    }
                    
                    TextEditor(text: $comment)
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .comment)
                        .frame(minHeight: 80, maxHeight: 140)
                        .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm - MPSpacing.xxs)
                        .padding(.bottom, MPSpacing.xs)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
        .sheet(isPresented: $showCategoryPicker) {
            NavigationStack {
                CategoryPickerView(
                    selectedCategory: categoryBinding,
                    transactionType: transactionType,
                    onDismissAll: { showCategoryPicker = false }
                )
            }
        }
    }
    
    // MARK: - Универсальная строка формы
    
    private func formRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: MPSpacing.sm) {
            Text(icon)
                .font(.system(size: 20))
                .frame(width: 28)
            
            Text(label)
                .font(MPTypography.body)
                .foregroundColor(MPColors.textPrimary)
            
            Spacer()
            
            content()
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
    }
    
    // MARK: - Сохранение
    
    private func saveTransaction() {
        guard canSave else { return }
        
        let transaction = TransactionModel(
            type: transactionType,
            amount: amountValue,
            currency: settings.defaultCurrency,
            transactionDate: transactionDate,
            comment: comment.isEmpty ? nil : comment,
            category: selectedCategory
        )
        
        modelContext.insert(transaction)
        try? modelContext.save()
        
        dismiss()
    }
    
    // MARK: - Helpers
    
    private var currencySymbol: String {
        switch settings.defaultCurrency {
        case "USD": return "$"
        case "EUR": return "€"
        default: return "₽"
        }
    }
}

// MARK: - Preview

#Preview("Добавить транзакцию — тёмная") {
    AddTransactionSheet()
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

#Preview("Добавить транзакцию — светлая") {
    AddTransactionSheet()
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
