// MonPapa iOS — Компактная сводка активных долгов (дашборд)

import SwiftUI

struct ActiveDebtsSummary: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let debts: [DebtModel]
    var onTapDebt: ((DebtModel) -> Void)?
    var onShowAll: (() -> Void)?

    /// Показываем максимум 3 pill-карточки
    private let maxVisible = 3

    var body: some View {
        if debts.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: MPSpacing.sm) {
                // Заголовок
                HStack {
                    Text(String(localized: "Активные долги"))
                        .font(MPTypography.button)
                        .foregroundColor(MPColors.textPrimary)

                    Spacer()

                    if debts.count > maxVisible, let onShowAll {
                        Button(action: onShowAll) {
                            Text(String(localized: "Все →"))
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(MPColors.accentCoral)
                        }
                    }
                }

                // Горизонтальный скролл pill-карточек
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MPSpacing.sm) {
                        ForEach(Array(debts.prefix(maxVisible)), id: \.clientId) { debt in
                            debtPill(debt)
                                .onTapGesture {
                                    onTapDebt?(debt)
                                }
                        }

                        // Badge «ещё N»
                        if debts.count > maxVisible {
                            moreBadge(count: debts.count - maxVisible)
                                .onTapGesture {
                                    onShowAll?()
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pill-карточка долга

    private func debtPill(_ debt: DebtModel) -> some View {
        HStack(spacing: MPSpacing.xs) {
            // Иконка направления
            Image(systemName: debt.direction == .gave ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(debt.direction == .gave ? MPColors.accentGreen : MPColors.accentCoral)
                )

            VStack(alignment: .leading, spacing: 1) {
                // Имя контрагента
                Text(debt.counterpart?.name ?? String(localized: "Без имени"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
                    .lineLimit(1)

                // Остаток
                Text(settings.hideAmounts ? "•••" : formatAmount(debt.remainingAmount))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(debt.direction == .gave ? MPColors.accentGreen : MPColors.accentCoral)
            }

            // Индикатор просрочки
            if debt.isOverdue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, MPSpacing.sm)
        .padding(.vertical, MPSpacing.xs + 2)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.pill)
        .overlay(
            RoundedRectangle(cornerRadius: MPCornerRadius.pill)
                .strokeBorder(
                    debt.isOverdue
                        ? Color.orange.opacity(0.4)
                        : MPColors.separator.opacity(0.3),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Badge «ещё N»

    private func moreBadge(count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(MPColors.accentCoral)
            .frame(width: 44, height: 44)
            .background(MPColors.accentCoral.opacity(0.1))
            .clipShape(Circle())
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
