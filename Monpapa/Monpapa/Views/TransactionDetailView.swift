// MonPapa iOS — Просмотр и редактирование транзакции

import SwiftUI
import SwiftData

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let transaction: TransactionModel

    // MARK: - UI State

    @State private var showDeleteConfirm = false
    @State private var showRawText = false
    @State private var isEditing = false
    @State private var showCategoryPicker = false
    @State private var selectedDetent: PresentationDetent = .medium

    // MARK: - Edit State (временные переменные — apply при Save, discard при Cancel)

    @State private var editAmount = ""
    @State private var editType: TransactionType = .expense
    @State private var editDate = Date()
    @State private var editComment = ""
    @State private var editExpenseCategory: CategoryModel?
    @State private var editIncomeCategory: CategoryModel?

    /// Текущая категория в зависимости от выбранного типа
    private var editCategory: CategoryModel? {
        switch editType {
        case .expense: editExpenseCategory
        case .income: editIncomeCategory
        }
    }

    /// Binding для CategoryPickerView
    private var editCategoryBinding: Binding<CategoryModel?> {
        switch editType {
        case .expense: $editExpenseCategory
        case .income: $editIncomeCategory
        }
    }

    @FocusState private var focusedField: EditField?

    private enum EditField {
        case amount, comment
    }

    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil }) private var allCategories: [CategoryModel]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: — Сумма
                        amountSection

                        // MARK: — Карточка с деталями
                        detailsCard

                        // MARK: — Распознанный текст AI (сворачиваемый, только в read mode)
                        if !isEditing, shouldShowRawText {
                            rawTextSection
                        }

                        // MARK: — Кнопка удаления (только в read mode)
                        if !isEditing {
                            deleteButton
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isEditing {
                        Button("Отмена") { cancelEditing() }
                            .foregroundColor(MPColors.textSecondary)
                    } else {
                        Button("Закрыть") { dismiss() }
                            .foregroundColor(MPColors.accentCoral)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(isEditing ? "Редактирование" : "Детали операции")
                        .font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Сохранить") { saveEdits() }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(editAmountValue > 0 ? MPColors.accentCoral : MPColors.textSecondary)
                            .disabled(editAmountValue <= 0)
                    } else {
                        Button {
                            startEditing()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(MPColors.accentCoral)
                        }
                    }
                }
            }
            .alert("Удалить транзакцию?", isPresented: $showDeleteConfirm) {
                Button("Удалить", role: .destructive) { deleteTransaction() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Транзакция будет удалена.")
            }
            .presentationDetents([.medium, .large], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
            .sheet(isPresented: $showCategoryPicker) {
                NavigationStack {
                    CategoryPickerView(
                        selectedCategory: editCategoryBinding,
                        transactionType: editType
                    )
                }
            }
        }
    }

    // MARK: - Сумма

    private var amountSection: some View {
        VStack(spacing: MPSpacing.xxs) {
            if isEditing {
                // Edit mode: TextField
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("0", text: $editAmount)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(editAmountColor)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .focused($focusedField, equals: .amount)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(currencySymbol)
                        .font(.system(size: 38, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }

                // Сегмент Расход / Доход
                typeSegment
            } else {
                // Read mode: статичный текст
                Text(formattedAmount)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(amountColor)

                Text(transaction.type == .income ? "Доход" : "Расход")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MPSpacing.md)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    // MARK: - Сегмент типа

    private var typeSegment: some View {
        HStack(spacing: 4) {
            segmentButton(title: "Расход", type: .expense, color: MPColors.accentCoral)
            segmentButton(title: "Доход", type: .income, color: MPColors.accentGreen)
        }
        .padding(4)
        .background(MPColors.cardBackground.opacity(0.6))
        .cornerRadius(MPCornerRadius.pill)
        .padding(.horizontal, MPSpacing.xl)
    }

    private func segmentButton(title: String, type: TransactionType, color: Color) -> some View {
        let isSelected = editType == type

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                editType = type
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

    // MARK: - Карточка с деталями

    private var detailsCard: some View {
        VStack(spacing: 0) {
            // 📅 Дата
            if isEditing {
                detailRow(icon: "📅", label: "Дата") {
                    DatePicker("", selection: $editDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(MPColors.accentCoral)
                }
            } else {
                detailRow(icon: "📅", label: "Дата") {
                    Text(transaction.transactionDate, format: .dateTime.day().month(.wide).year())
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)
                }
            }

            Divider()
                .padding(.leading, 52)

            // 🏷️ Категория
            if isEditing {
                Button {
                    focusedField = nil
                    showCategoryPicker = true
                } label: {
                    detailRow(icon: editCategoryIcon, label: "Категория") {
                        HStack(spacing: MPSpacing.xxs) {
                            Text(editCategoryDisplayName)
                                .font(MPTypography.body)
                                .foregroundColor(MPColors.textPrimary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(MPColors.textSecondary.opacity(0.5))
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                detailRow(icon: categoryIcon, label: "Категория") {
                    Text(categoryDisplayName)
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)
                }
            }

            // 💬 Комментарий
            if isEditing {
                Divider()
                    .padding(.leading, 52)

                VStack(alignment: .leading, spacing: 0) {
                    detailRow(icon: "💬", label: "Комментарий") {
                        EmptyView()
                    }

                    ZStack(alignment: .topLeading) {
                        if editComment.isEmpty {
                            Text("Добавьте комментарий...")
                                .font(MPTypography.body)
                                .foregroundColor(MPColors.textSecondary.opacity(0.5))
                                .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm)
                                .padding(.vertical, MPSpacing.xxs + 1)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $editComment)
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .focused($focusedField, equals: .comment)
                            .frame(minHeight: 50, maxHeight: 100)
                            .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm - MPSpacing.xxs)
                            .padding(.bottom, MPSpacing.xs)
                    }
                }
            } else if let comment = transaction.comment, !comment.isEmpty {
                Divider()
                    .padding(.leading, 52)

                VStack(alignment: .leading, spacing: MPSpacing.xxs) {
                    detailRow(icon: "💬", label: "Комментарий") {
                        EmptyView()
                    }

                    Text(comment)
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)
                        .padding(.horizontal, MPSpacing.md)
                        .padding(.leading, 28 + MPSpacing.sm)
                        .padding(.bottom, MPSpacing.sm)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    // MARK: - Распознанный текст AI (сворачиваемый)

    private var shouldShowRawText: Bool {
        guard let rawText = transaction.rawText, !rawText.isEmpty else { return false }
        return rawText != transaction.comment
    }

    private var rawTextSection: some View {
        DisclosureGroup(isExpanded: $showRawText) {
            Text(transaction.rawText ?? "")
                .font(MPTypography.caption)
                .foregroundColor(MPColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, MPSpacing.xxs)
        } label: {
            HStack(spacing: MPSpacing.xs) {
                Text("🤖")
                    .font(.system(size: 16))
                Text("Распознанный текст AI")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary)
            }
        }
        .tint(MPColors.textSecondary)
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Кнопка удаления

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: MPSpacing.xxs) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                Text("Удалить")
                    .font(MPTypography.caption)
            }
            .foregroundColor(MPColors.textSecondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, MPSpacing.xs)
    }

    // MARK: - Универсальная строка деталей

    private func detailRow<Content: View>(
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
                .foregroundColor(MPColors.textSecondary)

            Spacer()

            content()
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
    }

    // MARK: - Helpers (Read)

    private var amountColor: Color {
        transaction.type == .income ? MPColors.accentGreen : MPColors.accentCoral
    }

    private var formattedAmount: String {
        let sign = transaction.type == .income ? "+" : "-"
        let number = NSDecimalNumber(decimal: transaction.amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        let formatted = formatter.string(from: number) ?? "\(transaction.amount)"
        return "\(sign)\(formatted) \(currencySymbol)"
    }

    private var currencySymbol: String {
        switch transaction.currency {
        case "USD": return "$"
        case "EUR": return "€"
        default: return "₽"
        }
    }

    private var categoryIcon: String {
        transaction.category?.effectiveIcon ?? "🏷️"
    }

    private var categoryDisplayName: String {
        guard let category = transaction.category else { return "Без категории" }
        if let parent = category.parent {
            return "\(parent.name) › \(category.name)"
        }
        return category.name
    }

    // MARK: - Helpers (Edit)

    private var editAmountColor: Color {
        editType == .income ? MPColors.accentGreen : MPColors.accentCoral
    }

    private var editAmountValue: Decimal {
        let cleaned = editAmount
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }

    private var editCategoryIcon: String {
        editCategory?.effectiveIcon ?? "🏷️"
    }

    private var editCategoryDisplayName: String {
        guard let category = editCategory else { return "Без категории" }
        if let parent = category.parent {
            return "\(parent.name) › \(category.name)"
        }
        return category.name
    }

    // MARK: - Действия

    private func startEditing() {
        // Копируем текущие значения во временные переменные
        editType = transaction.type
        editDate = transaction.transactionDate
        editComment = transaction.comment ?? ""
        // Категория — в правильный слот по типу, другой обнуляем
        switch transaction.type {
        case .expense:
            editExpenseCategory = transaction.category
            editIncomeCategory = nil
        case .income:
            editIncomeCategory = transaction.category
            editExpenseCategory = nil
        }

        let number = NSDecimalNumber(decimal: transaction.amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        editAmount = formatter.string(from: number) ?? "\(transaction.amount)"

        withAnimation {
            isEditing = true
            selectedDetent = .large
        }
    }

    private func cancelEditing() {
        focusedField = nil
        withAnimation {
            isEditing = false
            selectedDetent = .medium
        }
    }

    private func saveEdits() {
        focusedField = nil

        transaction.type = editType
        transaction.amount = editAmountValue
        transaction.transactionDate = editDate
        transaction.comment = editComment.isEmpty ? nil : editComment
        transaction.category = editCategory
        transaction.updatedAt = Date()

        try? modelContext.save()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)

        withAnimation {
            isEditing = false
            selectedDetent = .medium
        }
    }

    private func deleteTransaction() {
        transaction.deletedAt = Date()
        transaction.updatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        dismiss()
    }
}

// MARK: - Preview

#Preview("Расход — тёмная") {
    TransactionDetailView(transaction: {
        let cat = CategoryModel(name: "Продукты", type: .expense, icon: "🛒")
        let tx = TransactionModel(
            type: .expense, amount: 1520, currency: "RUB",
            transactionDate: Date(), comment: "Пятёрочка", rawText: "купил продуктов в пятёрочке за 1520",
            category: cat
        )
        return tx
    }())
    .environmentObject(AppSettings())
    .modelContainer(for: [
        TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
    ], inMemory: true)
    .preferredColorScheme(.dark)
}

#Preview("Доход — светлая") {
    TransactionDetailView(transaction: {
        let cat = CategoryModel(name: "Зарплата", type: .income, icon: "💰")
        let tx = TransactionModel(
            type: .income, amount: 85000, currency: "RUB",
            transactionDate: Date(), comment: "Зарплата за март",
            category: cat
        )
        return tx
    }())
    .environmentObject(AppSettings())
    .modelContainer(for: [
        TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
    ], inMemory: true)
    .preferredColorScheme(.light)
}

#Preview("Без категории") {
    TransactionDetailView(transaction: TransactionModel(
        type: .expense, amount: 350, currency: "RUB",
        transactionDate: Date(), comment: "Что-то купил"
    ))
    .environmentObject(AppSettings())
    .modelContainer(for: [
        TransactionModel.self, CategoryModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
    ], inMemory: true)
    .preferredColorScheme(.dark)
}
