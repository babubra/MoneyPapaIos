// MonPapa iOS — Выбор долга для записи платежа
// Показывается когда у контрагента несколько активных долгов

import SwiftUI

struct DebtPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let debts: [DebtModel]
    let prefillAmount: Double?
    let onSelect: (DebtModel) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.md) {
                        // Заголовок-подсказка
                        HStack(spacing: MPSpacing.xs) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 16))
                                .foregroundColor(MPColors.accentCoral)
                            Text("Выберите, к какому долгу отнести платёж")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(MPColors.textSecondary)
                        }
                        .padding(.top, MPSpacing.xs)

                        // Карточки долгов
                        ForEach(debts, id: \.clientId) { debt in
                            Button {
                                onSelect(debt)
                                dismiss()
                            } label: {
                                debtCard(debt)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.bottom, MPSpacing.lg)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Несколько долгов")
                        .font(.system(size: 17, weight: .semibold))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
            }
        }
    }

    // MARK: - Карточка долга

    private func debtCard(_ debt: DebtModel) -> some View {
        HStack(spacing: MPSpacing.sm) {
            // Иконка направления
            ZStack {
                Circle()
                    .fill(debt.direction == .gave
                        ? MPColors.accentGreen.opacity(0.15)
                        : MPColors.accentCoral.opacity(0.15)
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: debt.direction == .gave
                    ? "arrow.up.right"
                    : "arrow.down.left"
                )
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(debt.direction == .gave
                    ? MPColors.accentGreen
                    : MPColors.accentCoral
                )
            }

            // Инфо
            VStack(alignment: .leading, spacing: 2) {
                Text(debt.direction == .gave ? "Дал в долг" : "Взял в долг")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)

                HStack(spacing: MPSpacing.xs) {
                    // Дата
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text(formattedDate(debt.debtDate))
                        .font(.system(size: 12, design: .rounded))

                    // Комментарий
                    if let comment = debt.comment, !comment.isEmpty {
                        Text("·")
                        Text(comment)
                            .lineLimit(1)
                            .font(.system(size: 12, design: .rounded))
                    }
                }
                .foregroundColor(MPColors.textSecondary)

                // Прогресс
                if debt.paidAmount > 0 {
                    Text("Оплачено: \(formattedAmount(debt.paidAmount)) из \(formattedAmount(debt.amount))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.accentCoral.opacity(0.8))
                }
            }

            Spacer()

            // Сумма (остаток)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedAmount(debt.remainingAmount))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(debt.direction == .gave
                        ? MPColors.accentGreen
                        : MPColors.accentCoral
                    )

                Text("остаток")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }

            // Шеврон
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(MPColors.textSecondary.opacity(0.5))
        }
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Helpers

    private func formattedAmount(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        let symbol: String
        switch settings.defaultCurrency {
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        default: symbol = "₽"
        }
        return (formatter.string(from: number) ?? "\(value)") + " " + symbol
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
