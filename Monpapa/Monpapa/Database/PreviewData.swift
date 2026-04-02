// MonPapa iOS — Тестовые данные для Preview и начальная загрузка

import Foundation
import SwiftData

// MARK: - Preview Data (для SwiftUI Canvas Preview)

/// Тестовые категории, транзакции и долги для использования в #Preview
enum PreviewData {
    
    // MARK: Категории
    
    static var categories: [CategoryModel] {
        [
            CategoryModel(name: "Зарплата", type: .income, icon: "💰"),
            CategoryModel(name: "Продукты", type: .expense, icon: "🛒"),
            CategoryModel(name: "Транспорт", type: .expense, icon: "🚗"),
            CategoryModel(name: "Кафе и рестораны", type: .expense, icon: "🍕"),
            CategoryModel(name: "Развлечения", type: .expense, icon: "🎬"),
            CategoryModel(name: "Здоровье", type: .expense, icon: "💊"),
            CategoryModel(name: "Одежда", type: .expense, icon: "👕"),
            CategoryModel(name: "Подарки", type: .expense, icon: "🎁"),
        ]
    }
    
    // MARK: Транзакции
    
    static var transactions: [TransactionModel] {
        let cats = categories
        return [
            TransactionModel(
                type: .income,
                amount: 45000,
                transactionDate: Date(),
                comment: "Зарплата за март",
                category: cats[0]
            ),
            TransactionModel(
                type: .expense,
                amount: 1520,
                transactionDate: Date().addingTimeInterval(-3600),
                comment: "Пятёрочка",
                category: cats[1]
            ),
            TransactionModel(
                type: .expense,
                amount: 350,
                transactionDate: Date().addingTimeInterval(-7200),
                comment: "Такси до работы",
                category: cats[2]
            ),
            TransactionModel(
                type: .expense,
                amount: 890,
                transactionDate: Date().addingTimeInterval(-86400),
                comment: "Обед с коллегами",
                category: cats[3]
            ),
            TransactionModel(
                type: .expense,
                amount: 2500,
                transactionDate: Date().addingTimeInterval(-172800),
                comment: "Подарок маме",
                category: cats[7]
            ),
        ]
    }
    
    // MARK: Контрагенты
    
    static var counterparts: [CounterpartModel] {
        [
            CounterpartModel(name: "Вася", icon: "👤"),
            CounterpartModel(name: "Мама", icon: "👩"),
        ]
    }
    
    // MARK: Сводка
    
    static var totalIncome: Decimal { 45000 }
    static var totalExpenses: Decimal { 5260 }
    static var balance: Decimal { totalIncome - totalExpenses }
}

// MARK: - Seed Data (для первого запуска)

struct SeedData {
    
    /// Заполняет базу начальными данными при первом запуске
    /// Сейчас приложение стартует с чистой БД — пользователь сам создаёт категории
    static func seedIfNeeded(context: ModelContext) {
        // Пустой — никаких предустановленных данных
    }
}
