// MonPapa iOS — Карточка баланса (дашборд)

import SwiftUI

struct BalanceCardView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    let monthlyBalance: Decimal
    let monthlyIncome: Decimal
    let monthlyExpenses: Decimal

    @State private var currentTime = Date()

    // MARK: - Кэшированные форматтеры

    private static let dayOfWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()

    // MARK: - Вычисляемые свойства

    private var formattedDayOfWeek: String {
        Self.dayOfWeekFormatter.string(from: currentTime).capitalizedFirstLetter
    }

    private var formattedDayMonth: String {
        Self.dayMonthFormatter.string(from: currentTime)
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 0) {

            // — Левая треть: дата
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDayOfWeek)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.balanceTextPrimary(colorScheme))
                    .lineLimit(1)

                Text(formattedDayMonth)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.balanceTextPrimary(colorScheme))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            // Вертикальный разделитель
            Rectangle()
                .fill(MPColors.balanceTextSecondary(colorScheme).opacity(0.2))
                .frame(width: 0.5)
                .padding(.vertical, 6)
                .padding(.leading, MPSpacing.md)
                .padding(.trailing, MPSpacing.md)

            // — Правые две трети: баланс + доходы/расходы
            VStack(alignment: .center, spacing: 4) {
                Text(String(localized: "Баланс"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.balanceTextSecondary(colorScheme))

                Text(settings.hideAmounts ? "••••••" : formatAmount(monthlyBalance))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.balanceTextPrimary(colorScheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                HStack(spacing: 0) {
                    // Доходы
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(MPColors.balanceIncome(colorScheme))

                        VStack(alignment: .leading, spacing: 0) {
                            Text(settings.hideAmounts ? "•••" : formatAmount(monthlyIncome))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(MPColors.balanceIncome(colorScheme))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(String(localized: "доходы"))
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundColor(MPColors.balanceTextSecondary(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Разделитель
                    Rectangle()
                        .fill(MPColors.balanceTextSecondary(colorScheme).opacity(0.2))
                        .frame(width: 0.5, height: 24)

                    // Расходы
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(MPColors.balanceExpense(colorScheme))

                        VStack(alignment: .leading, spacing: 0) {
                            Text(settings.hideAmounts ? "•••" : formatAmount(monthlyExpenses))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(MPColors.balanceExpense(colorScheme))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(String(localized: "расходы"))
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundColor(MPColors.balanceTextSecondary(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity)
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
        .onAppear {
            currentTime = Date()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                currentTime = Date()
            }
        }
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
