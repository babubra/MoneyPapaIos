// MonPapa iOS — Строка транзакции (переиспользуемый компонент)

import SwiftUI

struct TransactionRow: View {
    let icon: String?
    let name: String
    let category: String
    let amount: Decimal
    let type: TransactionType
    let currency: String
    
    init(transaction: TransactionModel) {
        self.icon = transaction.category?.effectiveIcon
        self.name = transaction.comment ?? "Без описания"
        self.category = transaction.category?.name ?? ""
        self.amount = transaction.amount
        self.type = transaction.type
        self.currency = transaction.currency
    }
    
    init(icon: String? = nil, name: String, category: String, amount: Decimal, type: TransactionType, currency: String = "₽") {
        self.icon = icon
        self.name = name
        self.category = category
        self.amount = amount
        self.type = type
        self.currency = currency
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
            
            // Сумма с цветом
            Text(formattedAmount)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(type == .income ? MPColors.accentGreen : MPColors.accentCoral)
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
