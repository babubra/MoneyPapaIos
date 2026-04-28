// MonPapa iOS — Форма добавления платежа по долгу

import SwiftUI
import SwiftData

struct AddPaymentSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let debt: DebtModel
    var prefillAmount: Double? = nil
    var prefillComment: String? = nil

    // MARK: - Поля формы

    @State private var amountText = ""
    @State private var paymentDate = Date()
    @State private var comment = ""

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

    /// Превышает ли введённая сумма остаток долга
    private var isOverpaying: Bool {
        amountValue > debt.remainingAmount
    }

    private var canSave: Bool {
        amountValue > 0 && !isOverpaying
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // Инфо о долге
                        debtInfoHeader

                        // Ввод суммы
                        amountInput

                        // Карточка формы
                        formCard

                        // Подсказка: оставшаяся сумма
                        if !settings.hideAmounts {
                            remainingHint
                        }
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
                    Text("Записать платёж")
                        .font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(canSave ? MPColors.accentCoral : MPColors.textSecondary)
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Инфо о долге

    private var debtInfoHeader: some View {
        HStack(spacing: MPSpacing.sm) {
            Text(debt.counterpart?.icon ?? "👤")
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 2) {
                Text(debt.counterpart?.name ?? "Без имени")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)

                Text(debt.direction == .gave ? "Дал в долг" : "Взял в долг")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(settings.hideAmounts ? "••• ₽" : formattedAmount(debt.amount))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)

                Text("остаток: \(settings.hideAmounts ? "•••" : formattedAmount(debt.remainingAmount))")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }

    // MARK: - Ввод суммы

    private var amountInput: some View {
        VStack(spacing: MPSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("0", text: $amountText)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(isOverpaying ? .red.opacity(0.7) : MPColors.textPrimary)
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
            .padding(.vertical, MPSpacing.md)

            // Кнопка «Вся сумма»
            Button {
                amountText = formatAmountText(String(describing: debt.remainingAmount))
            } label: {
                Text("Вся сумма (\(formattedAmount(debt.remainingAmount)))")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.accentCoral)
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.vertical, MPSpacing.xs)
                    .background(MPColors.accentCoral.opacity(0.1))
                    .cornerRadius(MPCornerRadius.pill)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            if let prefill = prefillAmount, prefill > 0 {
                amountText = formatAmountText(String(format: "%.0f", prefill))
            }
            if let preC = prefillComment, !preC.isEmpty {
                comment = preC
            }
            focusedField = .amount
        }
    }

    // MARK: - Карточка формы

    private var formCard: some View {
        VStack(spacing: 0) {
            // 📅 Дата платежа
            formRow(icon: "📅", label: "Дата платежа") {
                DatePicker("", selection: $paymentDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(MPColors.accentCoral)
            }

            Divider().padding(.leading, 52)

            // 💬 Комментарий
            VStack(alignment: .leading, spacing: 0) {
                formRow(icon: "💬", label: "Комментарий") {
                    EmptyView()
                }

                ZStack(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text("Вернул часть, перевод на карту...")
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
                        .frame(minHeight: 60, maxHeight: 100)
                        .padding(.horizontal, MPSpacing.md + 28 + MPSpacing.sm - MPSpacing.xxs)
                        .padding(.bottom, MPSpacing.xs)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Подсказка об остатке

    private var remainingHint: some View {
        Group {
            if amountValue > 0 {
                if isOverpaying {
                    // Превышение — красное предупреждение
                    HStack(spacing: MPSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Сумма превышает остаток (\(formattedAmount(debt.remainingAmount)))")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .transition(.opacity)
                } else {
                    let afterPayment = debt.remainingAmount - amountValue
                    HStack(spacing: MPSpacing.xs) {
                        if afterPayment == 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(MPColors.accentGreen)
                            Text("Долг будет полностью закрыт")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(MPColors.accentGreen)
                        } else {
                            Image(systemName: "info.circle")
                                .foregroundColor(MPColors.textSecondary)
                            Text("Останется: \(formattedAmount(afterPayment))")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(MPColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Строка формы

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

        let payment = DebtPaymentModel(
            amount: amountValue,
            paymentDate: paymentDate,
            comment: comment.isEmpty ? nil : comment,
            debt: debt
        )
        modelContext.insert(payment)

        // paidAmount теперь вычисляется из payments автоматически
        // Обновляем paidAmountString для синхронизации с бэкендом
        let newPaid = debt.paidAmount  // уже включает новый платёж через computed property
        debt.paidAmountString = "\(newPaid)"

        // Автозакрытие
        if newPaid >= debt.amount {
            debt.isClosed = true
        }

        debt.updatedAt = Date()
        try? modelContext.save()

        #if DEBUG
        print("[AddPayment] 💰 Платёж: \(amountValue) ₽, paidAmount=\(newPaid), остаток=\(debt.remainingAmount), долг \(debt.isClosed ? "закрыт ✅" : "активен")")
        #endif

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

    private func formattedAmount(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: number) ?? "\(amount)") + " ₽"
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
