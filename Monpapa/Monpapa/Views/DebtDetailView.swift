// MonPapa iOS — Детали долга (sheet)

import SwiftUI
import SwiftData

struct DebtDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings

    @Bindable var debt: DebtModel

    // MARK: - UI State

    @State private var showAddPayment = false
    @State private var showEditDebt = false
    @State private var showDeleteAlert = false

    // MARK: - Computed

    private var sortedPayments: [DebtPaymentModel] {
        debt.payments
            .filter { $0.deletedAt == nil }
            .sorted { $0.paymentDate > $1.paymentDate }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // MARK: — Шапка: контрагент + направление
                        headerCard

                        // MARK: — Суммы + прогресс
                        amountCard

                        // MARK: — Информация
                        infoCard

                        // MARK: — История платежей
                        paymentsSection

                        // MARK: — Действия
                        if !debt.isClosed {
                            actionsSection
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.xl)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showEditDebt = true
                        } label: {
                            Label("Редактировать", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(MPColors.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showAddPayment) {
                AddPaymentSheet(debt: debt)
            }
            .sheet(isPresented: $showEditDebt) {
                AddDebtSheet(editDebt: debt)
            }
            .alert("Удалить долг?", isPresented: $showDeleteAlert) {
                Button("Удалить", role: .destructive) { deleteDebt() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Долг и все платежи по нему будут удалены.")
            }
        }
    }

    // MARK: - Шапка

    private var headerCard: some View {
        VStack(spacing: MPSpacing.xs) {
            Text(debt.counterpart?.icon ?? (debt.direction == .gave ? "📤" : "📥"))
                .font(.system(size: 44))

            Text(debt.counterpart?.name ?? "Без имени")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)

            Text(debt.direction == .gave ? "Дал в долг" : "Взял в долг")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.textSecondary)

            if debt.isClosed {
                Label("Долг закрыт", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.accentGreen)
                    .padding(.top, MPSpacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MPSpacing.md)
    }

    // MARK: - Суммы + прогресс

    private var amountCard: some View {
        VStack(spacing: MPSpacing.sm) {
            if debt.isClosed {
                // Закрытый долг — просто сумма
                Text(settings.hideAmounts ? "•••••• ₽" : formattedAmount(debt.amount))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            } else if debt.paidAmount > 0 {
                // Есть платежи — показываем остаток крупно
                VStack(spacing: 2) {
                    Text(settings.hideAmounts ? "•••••• ₽" : formattedAmount(debt.remainingAmount))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)

                    Text("остаток из \(settings.hideAmounts ? "•••" : formattedAmount(debt.amount))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }

                // Инфо: выплачено / остаток
                HStack(spacing: MPSpacing.md) {
                    VStack(spacing: 2) {
                        Text(settings.hideAmounts ? "•••" : formattedAmount(debt.paidAmount))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(MPColors.accentGreen)
                        Text("выплачено")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundColor(MPColors.textSecondary)
                    }

                    VStack(spacing: 2) {
                        Text(settings.hideAmounts ? "•••" : formattedAmount(debt.remainingAmount))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(MPColors.accentCoral)
                        Text("остаток")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundColor(MPColors.textSecondary)
                    }
                }

                // Прогресс-бар
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MPColors.textSecondary.opacity(0.15))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(MPColors.accentGreen)
                            .frame(width: max(4, geo.size.width * progressFraction), height: 8)
                    }
                }
                .frame(height: 8)

                Text("\(progressPercent)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.accentGreen)
            } else {
                // Без платежей — полная сумма + пустой прогресс-бар
                Text(settings.hideAmounts ? "•••••• ₽" : formattedAmount(debt.amount))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)

                // Прогресс-бар (пустой)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(MPColors.textSecondary.opacity(0.15))
                        .frame(height: 8)
                }
                .frame(height: 8)

                Text("\(formattedAmount(0)) из \(formattedAmount(debt.amount))")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MPSpacing.md)
        .padding(.horizontal, MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Информация

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow(icon: "📅", label: "Дата долга", value: formattedFullDate(debt.debtDate))

            if let dueDate = debt.dueDate {
                Divider().padding(.leading, 52)
                infoRow(
                    icon: debt.isOverdue ? "⚠️" : "⏰",
                    label: "Срок возврата",
                    value: formattedFullDate(dueDate),
                    valueColor: debt.isOverdue ? .red : nil
                )
            }

            if let comment = debt.comment, !comment.isEmpty {
                Divider().padding(.leading, 52)
                infoRow(icon: "💬", label: "Комментарий", value: comment)
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    private func infoRow(icon: String, label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: MPSpacing.sm) {
            Text(icon)
                .font(.system(size: 20))
                .frame(width: 28)

            Text(label)
                .font(MPTypography.body)
                .foregroundColor(MPColors.textPrimary)

            Spacer()

            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(valueColor ?? MPColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
    }

    // MARK: - Платежи

    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            Text("История платежей")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(MPColors.textSecondary)

            if sortedPayments.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: MPSpacing.xs) {
                        Text("💸")
                            .font(.system(size: 28))
                        Text("Пока нет платежей")
                            .font(MPTypography.caption)
                            .foregroundColor(MPColors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, MPSpacing.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedPayments.enumerated()), id: \.element.clientId) { index, payment in
                        paymentRow(payment)

                        if index < sortedPayments.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.md)
            }
        }
    }

    private func paymentRow(_ payment: DebtPaymentModel) -> some View {
        HStack(spacing: MPSpacing.sm) {
            Text("💰")
                .font(.system(size: 20))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(settings.hideAmounts ? "••• ₽" : formattedAmount(payment.amount))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.accentGreen)

                if let comment = payment.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(MPColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(formattedShortDate(payment.paymentDate))
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(MPColors.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
    }

    // MARK: - Действия

    private var actionsSection: some View {
        VStack(spacing: MPSpacing.sm) {
            // Кнопка «Записать платёж»
            Button {
                showAddPayment = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                    Text("Записать платёж")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm + 2)
                .background(MPColors.accentGreen.opacity(0.85))
                .cornerRadius(MPCornerRadius.pill)
            }
            .buttonStyle(.plain)

            // Кнопка «Закрыть долг»
            Button {
                closeDebt()
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16))
                    Text("Закрыть долг")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundColor(MPColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm + 2)
                .background(MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.pill)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func closeDebt() {
        debt.isClosed = true
        debt.paidAmountString = "\(debt.amount)"
        debt.updatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
    }

    private func deleteDebt() {
        debt.deletedAt = Date()
        debt.updatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        dismiss()
    }

    // MARK: - Helpers

    private var progressFraction: CGFloat {
        guard debt.amount > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: debt.paidAmount).doubleValue /
                       NSDecimalNumber(decimal: debt.amount).doubleValue
        return CGFloat(min(1, max(0, fraction)))
    }

    private var progressPercent: Int {
        Int(progressFraction * 100)
    }

    private func formattedAmount(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: number) ?? "\(amount)") + " ₽"
    }

    private func formattedFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    private func formattedShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "d MMM"
        } else {
            formatter.dateFormat = "d MMM yyyy"
        }
        return formatter.string(from: date)
    }
}
