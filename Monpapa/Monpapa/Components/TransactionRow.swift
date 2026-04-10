// MonPapa iOS — Строка транзакции (переиспользуемый компонент)

import SwiftUI

struct TransactionRow: View {
    @EnvironmentObject private var settings: AppSettings

    let icon: String?
    let name: String
    let category: String
    let amount: Decimal
    let type: TransactionType
    let currency: String
    let createdAt: Date?
    let showDate: Bool
    
    init(transaction: TransactionModel, showDate: Bool = true) {
        self.icon = transaction.category?.effectiveIcon
        self.name = transaction.comment ?? "Без описания"
        self.category = transaction.category?.name ?? ""
        self.amount = transaction.amount
        self.type = transaction.type
        self.currency = transaction.currency
        self.createdAt = transaction.createdAt
        self.showDate = showDate
    }
    
    init(icon: String? = nil, name: String, category: String, amount: Decimal, type: TransactionType, currency: String = "₽", createdAt: Date? = nil, showDate: Bool = true) {
        self.icon = icon
        self.name = name
        self.category = category
        self.amount = amount
        self.type = type
        self.currency = currency
        self.createdAt = createdAt
        self.showDate = showDate
    }
    
    var body: some View {
        HStack(spacing: MPSpacing.sm) {
            // Emoji иконка (только если есть)
            if let icon {
                Text(icon)
                    .font(.system(size: 28))
                    .frame(width: 40, height: 40)
            }
            
            // Название и категория
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.textPrimary)
                    .lineLimit(1)
                
                if !category.isEmpty {
                    Text(category)
                        .font(MPTypography.caption)
                        .foregroundColor(MPColors.textSecondary)
                }
            }
            
            Spacer()
            
            // Сумма и дата создания
            VStack(alignment: .trailing, spacing: 2) {
                Text(settings.hideAmounts ? "• • •  ₽" : formattedAmount)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(type == .income ? MPColors.accentGreen : MPColors.accentCoral)
                
                if let createdAt, showDate {
                    Text(formattedCreatedAt(createdAt))
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundColor(MPColors.textSecondary.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }
    
    private var formattedAmount: String {
        let sign = type == .income ? "+" : "-"
        let number = NSDecimalNumber(decimal: amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: number) ?? "\(amount)"
        return "\(sign)\(formatted) ₽"
    }
    
    /// Форматирование даты создания: «7 апр, 14:30»
    private func formattedCreatedAt(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        
        if calendar.isDateInToday(date) {
            // Сегодня — показываем только время
            formatter.dateFormat = "'сегодня,' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'вчера,' HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            // Этот год — без года
            formatter.dateFormat = "d MMM, HH:mm"
        } else {
            formatter.dateFormat = "d MMM yyyy, HH:mm"
        }
        
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview("Строка транзакции") {
    VStack(spacing: MPSpacing.xs) {
        TransactionRow(
            icon: "💰", name: "Зарплата за март",
            category: "Зарплата", amount: 45000, type: .income
        )
        TransactionRow(
            icon: "🛒", name: "Пятёрочка",
            category: "Продукты", amount: 1520, type: .expense
        )
        TransactionRow(
            icon: "🚗", name: "Такси до работы",
            category: "Транспорт", amount: 350, type: .expense
        )
    }
    .padding()
    .background(MPColors.background)
}
