// MonPapa iOS — Карточка долга (компонент для списка)

import SwiftUI

struct DebtCard: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let debt: DebtModel

    var body: some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            // MARK: — Шапка: контрагент + статус
            HStack {
                // Иконка контрагента
                Text(debt.counterpart?.icon ?? (debt.direction == .gave ? "📤" : "📥"))
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(debt.counterpart?.name ?? "Без имени")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)
                        .lineLimit(1)

                    Text(debt.direction == .gave ? "Дал в долг" : "Взял в долг")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }

                Spacer()

                // Сумма / статус
                VStack(alignment: .trailing, spacing: 2) {
                    if debt.isClosed {
                        // Закрыт — показываем полную сумму серым
                        Text(settings.hideAmounts ? "• • •  ₽" : formattedAmount(debt.amount))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(MPColors.textSecondary)

                        Label("Закрыт", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(MPColors.accentGreen)
                    } else if debt.paidAmount > 0 {
                        // Частично оплачен — показываем остаток
                        Text(settings.hideAmounts ? "• • •  ₽" : formattedAmount(debt.remainingAmount))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(amountColor)

                        if debt.isOverdue {
                            Label("Просрочен", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.red)
                        }
                    } else {
                        // Без платежей — полная сумма
                        Text(settings.hideAmounts ? "• • •  ₽" : formattedAmount(debt.amount))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(amountColor)

                        if debt.isOverdue {
                            Label("Просрочен", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.red)
                        }
                    }
                }
            }

            // MARK: — Прогресс-бар (для всех активных долгов)
            if !debt.isClosed {
                VStack(spacing: MPSpacing.xxs) {
                    // Прогресс-бар
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(MPColors.textSecondary.opacity(0.15))
                                .frame(height: 6)

                            if progressFraction > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(progressColor)
                                    .frame(width: max(4, geo.size.width * progressFraction), height: 6)
                            }
                        }
                    }
                    .frame(height: 6)

                    // Текст прогресса
                    HStack {
                        if !settings.hideAmounts {
                            Text("\(formattedAmount(debt.paidAmount)) из \(formattedAmount(debt.amount))")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundColor(MPColors.textSecondary)
                        }

                        Spacer()

                        if debt.paidAmount > 0 {
                            Text("\(progressPercent)%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(progressColor)
                        }
                    }
                }
            }

            // MARK: — Нижняя строка: дата + срок
            HStack {
                // Дата создания
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                    Text(formattedDate(debt.debtDate))
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                }
                .foregroundColor(MPColors.textSecondary.opacity(0.7))

                Spacer()

                // Срок возврата
                if let dueDate = debt.dueDate, !debt.isClosed {
                    if let days = debt.daysUntilDue {
                        HStack(spacing: 3) {
                            Image(systemName: days < 0 ? "exclamationmark.circle" : "clock")
                                .font(.system(size: 10))
                            Text(dueText(days: days, dueDate: dueDate))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(days < 0 ? .red : (days <= 3 ? .orange : MPColors.textSecondary.opacity(0.7)))
                    }
                }

                // Комментарий (маркер)
                if let comment = debt.comment, !comment.isEmpty {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10))
                        .foregroundColor(MPColors.textSecondary.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm + 2)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }

    // MARK: - Helpers

    private var amountColor: Color {
        if debt.isClosed {
            return MPColors.textSecondary
        }
        return debt.direction == .gave ? MPColors.accentGreen : MPColors.accentCoral
    }

    private var progressFraction: CGFloat {
        guard debt.amount > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: debt.paidAmount).doubleValue /
                       NSDecimalNumber(decimal: debt.amount).doubleValue
        return CGFloat(min(1, max(0, fraction)))
    }

    private var progressPercent: Int {
        Int(progressFraction * 100)
    }

    private var progressColor: Color {
        if progressFraction >= 0.75 {
            return MPColors.accentGreen
        } else if progressFraction >= 0.4 {
            return MPColors.accentYellow
        } else {
            return MPColors.accentBlue
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

    private func formattedDate(_ date: Date) -> String {
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

    private func dueText(days: Int, dueDate: Date) -> String {
        if days < 0 {
            return "просрочен на \(abs(days)) дн."
        } else if days == 0 {
            return "сегодня"
        } else if days <= 7 {
            return "через \(days) дн."
        } else {
            return formattedDate(dueDate)
        }
    }
}

// MARK: - Preview

#Preview("Карточка долга") {
    VStack(spacing: MPSpacing.sm) {
        Text("Примеры карточек")
            .font(MPTypography.screenTitle)
    }
    .padding()
    .background(MPColors.background)
    .environmentObject(AppSettings())
}
