// MonPapa iOS — Форма создания/редактирования долга

import SwiftUI
import SwiftData
import os

struct AddDebtSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @Query(filter: #Predicate<CounterpartModel> { $0.deletedAt == nil },
           sort: \CounterpartModel.name)
    private var allCounterparts: [CounterpartModel]

    // MARK: - Режим: создание / редактирование / AI prefill

    var editDebt: DebtModel?
    var prefill: AiParseResult?

    var isEditing: Bool { editDebt != nil }

    // MARK: - Поля формы

    @State private var direction: DebtDirection = .gave
    @State private var amountText = ""
    @State private var debtDate = Date()
    @State private var dueDate: Date? = nil
    @State private var showDueDate = false
    @State private var comment = ""

    // Контрагент
    @State private var selectedCounterpart: CounterpartModel?
    @State private var counterpartName = ""
    @State private var showCounterpartPicker = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case amount, comment, counterpart
    }

    // MARK: - Валидация

    private var amountValue: Decimal {
        let cleaned = amountText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }

    private var canSave: Bool {
        amountValue > 0 && (selectedCounterpart != nil || !counterpartName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: — Направление
                        directionSegment

                        // MARK: — Ввод суммы
                        amountInput

                        // MARK: — Карточка формы
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
                    Text(isEditing ? "Редактировать" : "Новый долг")
                        .font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(canSave ? MPColors.accentCoral : MPColors.textSecondary)
                        .disabled(!canSave)
                }
            }
            .task {
                applyEditData()
                applyPrefill()
            }
        }
    }

    // MARK: - Направление

    private var directionSegment: some View {
        HStack(spacing: 4) {
            directionButton(titleKey: "Я дал в долг", dir: .gave, color: MPColors.accentGreen)
            directionButton(titleKey: "Я взял в долг", dir: .took, color: MPColors.accentCoral)
        }
        .padding(4)
        .background(MPColors.cardBackground.opacity(0.6))
        .cornerRadius(MPCornerRadius.pill)
    }

    private func directionButton(titleKey: LocalizedStringKey, dir: DebtDirection, color: Color) -> some View {
        let isSelected = direction == dir

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                direction = dir
            }
        } label: {
            Text(titleKey)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .white : MPColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm)
                .background(
                    isSelected
                        ? AnyShapeStyle(color.opacity(0.85))
                        : AnyShapeStyle(.clear)
                )
                .cornerRadius(MPCornerRadius.pill - 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Ввод суммы

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
                .containerRelativeFrame(.horizontal)
            }
            .defaultScrollAnchor(.trailing)
            .padding(.vertical, MPSpacing.lg)
        }
        .onAppear {
            if !isEditing {
                focusedField = .amount
            }
        }
    }

    // MARK: - Карточка формы

    private var formCard: some View {
        VStack(spacing: 0) {
            // 👤 Контрагент
            counterpartRow

            Divider().padding(.leading, 52)

            // 📅 Дата долга
            formRow(icon: "📅", label: "Дата долга") {
                DatePicker("", selection: $debtDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(MPColors.accentCoral)
            }

            Divider().padding(.leading, 52)

            // ⏰ Срок возврата
            VStack(spacing: 0) {
                HStack(spacing: MPSpacing.sm) {
                    Text("⏰")
                        .font(.system(size: 20))
                        .frame(width: 28)

                    Text("Срок возврата")
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)

                    Spacer()

                    Toggle("", isOn: $showDueDate)
                        .labelsHidden()
                        .tint(MPColors.accentCoral)
                        .onChange(of: showDueDate) { _, on in
                            if on && dueDate == nil {
                                dueDate = Calendar.current.date(byAdding: .month, value: 1, to: debtDate)
                            }
                            if !on {
                                dueDate = nil
                            }
                        }
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.vertical, MPSpacing.sm)

                if showDueDate, let binding = dueDateBinding {
                    DatePicker("", selection: binding, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(MPColors.accentCoral)
                        .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm)
                        .padding(.bottom, MPSpacing.sm)
                }
            }

            Divider().padding(.leading, 52)

            // 💬 Комментарий
            VStack(alignment: .leading, spacing: 0) {
                formRow(icon: "💬", label: "Комментарий") {
                    EmptyView()
                }

                ZStack(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text("На ремонт, до зарплаты...")
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
                        .frame(minHeight: 60, maxHeight: 120)
                        .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm - MPSpacing.xxs)
                        .padding(.bottom, MPSpacing.xs)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Контрагент

    private var counterpartRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: MPSpacing.sm) {
                Text("👤")
                    .font(.system(size: 20))
                    .frame(width: 28)

                Text(direction == .gave ? "Кому" : "У кого")
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.textPrimary)

                Spacer()

                if let cp = selectedCounterpart {
                    HStack(spacing: 4) {
                        if let icon = cp.icon {
                            Text(icon)
                                .font(.system(size: 14))
                        }
                        Text(cp.name)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(MPColors.textPrimary)
                    }

                    Button {
                        selectedCounterpart = nil
                        counterpartName = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(MPColors.textSecondary.opacity(0.5))
                    }
                } else {
                    TextField("Имя...", text: $counterpartName)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .counterpart)
                }
            }
            .padding(.horizontal, MPSpacing.md)
            .padding(.vertical, MPSpacing.sm)

            // Подсказки (автодополнение)
            if selectedCounterpart == nil && !counterpartName.isEmpty {
                let matches = allCounterparts.filter {
                    $0.name.localizedCaseInsensitiveContains(counterpartName)
                }

                if !matches.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(matches.prefix(4), id: \.clientId) { cp in
                            Button {
                                selectedCounterpart = cp
                                counterpartName = cp.name
                                focusedField = nil
                            } label: {
                                HStack(spacing: MPSpacing.xs) {
                                    Text(cp.icon ?? "👤")
                                        .font(.system(size: 14))
                                    Text(cp.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(MPColors.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm)
                                .padding(.vertical, MPSpacing.xs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(MPColors.cardBackground.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Универсальная строка формы

    private func formRow<Content: View>(
        icon: String,
        label: LocalizedStringKey,
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

    // MARK: - Save

    private func save() {
        guard canSave else { return }

        // Разрешаем контрагента
        let counterpart = resolveCounterpart()

        if let debt = editDebt {
            // Режим редактирования
            debt.direction = direction
            debt.amount = amountValue
            debt.debtDate = debtDate
            debt.dueDate = dueDate
            debt.comment = comment.isEmpty ? nil : comment
            debt.counterpart = counterpart
            debt.updatedAt = Date()
        } else {
            // Создание нового долга
            let newDebt = DebtModel(
                direction: direction,
                amount: amountValue,
                debtDate: debtDate,
                dueDate: dueDate,
                currency: settings.defaultCurrency,
                comment: comment.isEmpty ? nil : comment,
                counterpart: counterpart
            )
            modelContext.insert(newDebt)
        }

        try? modelContext.save()

        MPLog.prefill.info("💾 Долг сохранён: \(direction.displayName, privacy: .public), \(amountValue, privacy: .public) ₽, контрагент: \(counterpart?.name ?? "nil", privacy: .public)")

        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        dismiss()
    }

    /// Находит существующего или создаёт нового контрагента
    private func resolveCounterpart() -> CounterpartModel? {
        // Если выбран существующий
        if let cp = selectedCounterpart {
            return cp
        }

        // Создаём нового по введённому имени
        let name = counterpartName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Проверяем на дубли (case-insensitive)
        if let existing = allCounterparts.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing
        }

        // Создаём нового
        let newCP = CounterpartModel(name: name)
        modelContext.insert(newCP)

        MPLog.prefill.info("🆕 Создан контрагент: \(name, privacy: .public)")

        return newCP
    }

    // MARK: - AI Prefill

    private func applyPrefill() {
        guard let result = prefill, result.status != .rejected else { return }

        MPLog.prefill.info("✨ AddDebt applyPrefill: type=\(result.type ?? "nil", privacy: .public) amount=\(result.amount ?? 0) cp=\(result.counterpartName ?? "nil", privacy: .public) cpId=\(result.counterpartId ?? "nil", privacy: .public) dueDate=\(result.dueDate ?? "nil", privacy: .public)")

        // Направление
        switch result.type {
        case "debt_give": direction = .gave
        case "debt_take": direction = .took
        case "debt_payment":
            // Для debt_payment направление не меняем — это платёж по существующему долгу,
            // но AddDebtSheet используется только для создания новых долгов.
            // debt_payment обрабатывается на уровне DashboardView.
            break
        default: break
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
                debtDate = date
            }
        }

        // Срок возврата
        if let dueDateStr = result.dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: dueDateStr) {
                dueDate = parsed
                showDueDate = true
            }
        }

        // Контрагент
        if let cpName = result.counterpartName, !cpName.isEmpty {
            // Попробуем найти существующего
            if let cpId = result.counterpartId,
               let existing = allCounterparts.first(where: { $0.clientId == cpId }) {
                selectedCounterpart = existing
                counterpartName = existing.name
            } else if let existing = allCounterparts.first(where: {
                $0.name.localizedCaseInsensitiveCompare(cpName) == .orderedSame
            }) {
                selectedCounterpart = existing
                counterpartName = existing.name
            } else {
                // Новый контрагент — заполняем имя, создание при save()
                counterpartName = cpName
            }
        }

        // Комментарий
        if let rawText = result.rawText, !rawText.isEmpty {
            comment = rawText
        }
    }

    // MARK: - Edit Data

    private func applyEditData() {
        guard let debt = editDebt else { return }
        direction = debt.direction
        amountText = formatAmountText(String(describing: debt.amount))
        debtDate = debt.debtDate
        dueDate = debt.dueDate
        showDueDate = debt.dueDate != nil
        comment = debt.comment ?? ""
        selectedCounterpart = debt.counterpart
        counterpartName = debt.counterpart?.name ?? ""
    }

    // MARK: - Helpers

    private var dueDateBinding: Binding<Date>? {
        guard dueDate != nil else { return nil }
        return Binding(
            get: { dueDate ?? Date() },
            set: { dueDate = $0 }
        )
    }

    private var currencySymbol: String {
        switch settings.defaultCurrency {
        case "USD": return "$"
        case "EUR": return "€"
        default: return "₽"
        }
    }

    private func formatAmountText(_ input: String) -> String {
        let allowedChars = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".,"))
        let filtered = input.unicodeScalars.filter { allowedChars.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: ",", with: ".")

        let parts = clean.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.isEmpty ? "" : String(parts[0])

        var formattedInt = ""
        for (index, char) in intPart.reversed().enumerated() {
            if index > 0, index % 3 == 0 {
                formattedInt.insert(" ", at: formattedInt.startIndex)
            }
            formattedInt.insert(char, at: formattedInt.startIndex)
        }

        if parts.count > 1 {
            return formattedInt + "," + String(parts[1])
        }
        if clean.hasSuffix(".") {
            return formattedInt + ","
        }
        return formattedInt
    }
}

// MARK: - Preview

#Preview("Создание — тёмная") {
    AddDebtSheet()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.dark)
}

#Preview("Создание — светлая") {
    AddDebtSheet()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self, CategoryModel.self,
            CounterpartModel.self, DebtModel.self, DebtPaymentModel.self
        ], inMemory: true)
        .preferredColorScheme(.light)
}
