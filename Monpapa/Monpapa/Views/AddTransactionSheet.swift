// MonPapa iOS — Форма добавления транзакции (ручная + AI)

import SwiftUI
import SwiftData

struct AddTransactionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings

    // MARK: - AI Prefill (опционально)

    /// Результат AI-парсинга. Если nil — обычное ручное создание.
    var prefill: AiParseResult?
    @State private var aiSuggestedCategoryName: String?
    @State private var aiSuggestedCategoryIcon: String?
    @State private var showAIGlow = false

    @State private var transactionType: TransactionType

    init(prefill: AiParseResult? = nil, defaultType: TransactionType = .expense) {
        self.prefill = prefill
        self._transactionType = State(initialValue: defaultType)
    }
    @State private var amountText = ""
    @State private var transactionDate = Date()
    @State private var selectedExpenseCategory: CategoryModel?
    @State private var selectedIncomeCategory: CategoryModel?
    @State private var comment = ""

    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil }) private var allCategories: [CategoryModel]
    
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
    
    /// Есть ли предложенная AI новая категория
    private var hasAISuggestedCategory: Bool {
        aiSuggestedCategoryName != nil && selectedCategory == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: — Сегмент Расход / Доход
                        typeSegment

                        // MARK: — Крупный ввод суммы (с AI glow)
                        amountInput
                            .aiBorderGlow(isActive: showAIGlow, cornerRadius: MPCornerRadius.lg)

                        // MARK: — Дата + Категория + Комментарий (карточка)
                        formCard
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
                ToolbarItem(placement: .principal) {
                    Text("Новая операция")
                        .font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { saveTransaction() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(canSave ? MPColors.accentCoral : MPColors.textSecondary)
                        .disabled(!canSave)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(100))
                applyPrefill()
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("0", text: $amountText)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .amount)
                        .fixedSize(horizontal: true, vertical: false)
                        .onChange(of: amountText) { _, newValue in
                            // Ограничим случайный спам символов
                            let limited = String(newValue.prefix(16))
                            let formatted = formatAmountText(limited)
                            if formatted != newValue {
                                amountText = formatted
                            }
                        }

                    Text(currencySymbol)
                        .font(.system(size: 46, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                        .fixedSize()
                }
                // Центрируем HStack внутри ScrollView
                .containerRelativeFrame(.horizontal)
            }
            // Авто-скролл к концу при печати (прилипает к правому краю)
            .defaultScrollAnchor(.trailing)
            .padding(.vertical, MPSpacing.lg)
        }
        .onAppear {
            // Открываем клавиатуру только если сумму нужно вводить вручную
            if prefill?.amount ?? 0 == 0 {
                focusedField = .amount
            }
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
                focusedField = nil // Принудительно скрываем клавиатуру
                showCategoryPicker = true
            } label: {
                HStack(spacing: MPSpacing.sm) {
                    if let cat = selectedCategory {
                        // Выбрана существующая категория
                        if let icon = cat.effectiveIcon {
                            Text(icon)
                                .font(.system(size: 20))
                                .frame(width: 28)
                        }

                        Text(categoryDisplayName(for: cat))
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                    } else if let suggestedName = aiSuggestedCategoryName {
                        // AI предложил новую категорию — показываем как выбранную
                        Text(aiSuggestedCategoryIcon ?? "🏷️")
                            .font(.system(size: 20))
                            .frame(width: 28)

                        Text(aiSuggestedCategoryDisplayName)
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text("✨ Новая")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.55, green: 0.35, blue: 0.95),
                                        Color(red: 0.30, green: 0.55, blue: 1.00),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())

                    } else {
                        // Не выбрана: лейбл + placeholder
                        Text("🏷️")
                            .font(.system(size: 20))
                            .frame(width: 28)

                        Text("Категория")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)

                        Spacer()

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
    
    // MARK: - AI Prefill

    private func applyPrefill() {
        guard let result = prefill, result.status != .rejected else { return }

        // Тип транзакции
        if let typeStr = result.type {
            switch typeStr {
            case "income":  transactionType = .income
            case "expense": transactionType = .expense
            default: break
            }
        }

        // Сумма
        if let amount = result.amount, amount > 0 {
            amountText = formatAmountText(String(format: "%.0f", amount))
        }

        // Дата
        if let dateStr = result.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: dateStr) {
                transactionDate = date
            }
        }

        // Категория — ищем по имени в SwiftData
        if let catName = result.categoryName {
            if result.categoryIsNew == true {
                // AI предложил новую категорию
                aiSuggestedCategoryName = catName
                aiSuggestedCategoryIcon = result.categoryIcon
            } else {
                // Ищем существующую
                let match = allCategories.first { $0.name.lowercased() == catName.lowercased() }
                if let match {
                    switch transactionType {
                    case .expense: selectedExpenseCategory = match
                    case .income: selectedIncomeCategory = match
                    }
                }
            }
        }

        // Комментарий — rawText от AI
        if let rawText = result.rawText, !rawText.isEmpty {
            comment = rawText
        }

        // Запускаем glow-эффекты
        withAnimation(.easeIn(duration: 0.3)) {
            showAIGlow = true
        }
    }

    // MARK: - Сохранение

    private func saveTransaction() {
        guard canSave else { return }

        var categoryToSave = selectedCategory

        // Если AI предложил новую категорию и пользователь не выбрал существующую
        if categoryToSave == nil, let suggestedName = aiSuggestedCategoryName {
            let newCategory = CategoryModel(
                name: suggestedName,
                type: transactionType,
                icon: aiSuggestedCategoryIcon
            )

            // Привязка к родительской категории (если AI указал parent)
            if let parentName = prefill?.categoryParentName {
                let parentMatch = allCategories.first {
                    $0.name.lowercased() == parentName.lowercased()
                }
                if let parent = parentMatch {
                    newCategory.parent = parent
                } else {
                    // Родительская тоже новая — создаём
                    let parentIcon = prefill?.categoryParentIcon
                    let newParent = CategoryModel(
                        name: parentName,
                        type: transactionType,
                        icon: parentIcon
                    )
                    modelContext.insert(newParent)
                    newCategory.parent = newParent
                }
            }

            modelContext.insert(newCategory)
            categoryToSave = newCategory
            #if DEBUG
            print("[AddTransaction] 🆕 Создана AI-категория: \(suggestedName)")
            #endif
        }

        // MARK: - Auto-Learn v1: отправка маппинга (item_phrase → category)
        // Отправляем маппинг на сервер (fire-and-forget) если есть item_phrase от AI
        if settings.aiAutoLearn,
           let itemPhrase = prefill?.itemPhrase,
           !itemPhrase.isEmpty,
           let chosen = categoryToSave {
            let aiSuggested = prefill?.categoryName
            let isOverride = (aiSuggested != nil && chosen.name != aiSuggested)
            
            Task {
                await AIService.shared.sendMapping(
                    itemPhrase: itemPhrase,
                    categoryId: chosen.clientId ?? "",
                    categoryName: chosen.name,
                    isOverride: isOverride
                )
            }
            #if DEBUG
            if isOverride {
                print("[AddTransaction] 🧠 Auto-Learn OVERRIDE: AI предложил «\(aiSuggested ?? "nil")», пользователь выбрал «\(chosen.name)» → маппинг: '\(itemPhrase)' → '\(chosen.name)'")
            } else {
                print("[AddTransaction] 🧠 Auto-Learn CONFIRM: '\(itemPhrase)' → '\(chosen.name)'")
            }
            #endif
        } else {
            #if DEBUG
            let itemPhrase = prefill?.itemPhrase ?? "nil"
            let chosenName = categoryToSave?.name ?? "nil"
            print("[AddTransaction] ℹ️ Auto-Learn пропущен: itemPhrase=\(itemPhrase), chosen=\(chosenName), autoLearn=\(settings.aiAutoLearn)")
            #endif
        }

        // TODO: Рассмотреть обязательность выбора категории перед сохранением.
        // Возможно показывать бейдж "Без категории" и экран "Нераспределённые".

        let transaction = TransactionModel(
            type: transactionType,
            amount: amountValue,
            currency: settings.defaultCurrency,
            transactionDate: transactionDate,
            comment: comment.isEmpty ? nil : comment,
            rawText: prefill?.rawText,
            category: categoryToSave
        )

        modelContext.insert(transaction)
        try? modelContext.save()
        
        #if DEBUG
        print("[AddTransaction] 💾 Транзакция сохранена: \(amountValue) \(settings.defaultCurrency), категория: \(categoryToSave?.name ?? "без категории")")
        #endif
        
        // Триггер автосинхронизации
        NotificationCenter.default.post(name: .dataDidChange, object: nil)

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

    private func categoryDisplayName(for category: CategoryModel) -> String {
        if let parent = category.parent {
            return "\(parent.name) › \(category.name)"
        }
        return category.name
    }

    private var aiSuggestedCategoryDisplayName: String {
        guard let name = aiSuggestedCategoryName else { return "" }
        if let parentName = prefill?.categoryParentName {
            return "\(parentName) › \(name)"
        }
        return name
    }
}

// MARK: - Preview

#Preview("Ручная — тёмная") {
    AddTransactionSheet()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.dark)
}

#Preview("Ручная — светлая") {
    AddTransactionSheet()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.light)
}

#Preview("AI — тёмная ✨") {
    AddTransactionSheet(prefill: AiParseResult(
        status: .ok, type: "expense", amount: 500, currency: "RUB", date: "2026-04-03",
        rawText: "потратил 500 на обед", itemPhrase: "обед", categoryId: nil, categoryName: "Кафе и рестораны",
        categoryIsNew: true, categoryIcon: "🍽️", categoryParentName: nil, categoryParentId: nil, categoryParentIcon: nil,
        counterpartId: nil, counterpartName: nil, counterpartIsNew: nil, message: nil
    ))
    .environmentObject(AppSettings())
    .modelContainer(for: [
        TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
    ], inMemory: true)
    .preferredColorScheme(.dark)
}

#Preview("AI — светлая ✨") {
    AddTransactionSheet(prefill: AiParseResult(
        status: .ok, type: "expense", amount: 500, currency: "RUB", date: "2026-04-03",
        rawText: "потратил 500 на обед", itemPhrase: "обед", categoryId: nil, categoryName: "Кафе и рестораны",
        categoryIsNew: true, categoryIcon: "🍽️", categoryParentName: nil, categoryParentId: nil, categoryParentIcon: nil,
        counterpartId: nil, counterpartName: nil, counterpartIsNew: nil, message: nil
    ))
    .environmentObject(AppSettings())
    .modelContainer(for: [
        TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
    ], inMemory: true)
    .preferredColorScheme(.light)
}
