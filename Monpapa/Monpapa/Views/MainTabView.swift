// MonPapa iOS — Главная навигация (TabView)

import SwiftUI
import SwiftData

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Таб 1: Главная
            DashboardView()
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                    Text("Главная")
                }
                .tag(0)
            
            // Таб 2: Транзакции
            TransactionListView()
                .tabItem {
                    Image(systemName: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    Text("Транзакции")
                }
                .tag(1)
            
            // Таб 3: Статистика
            StatsPlaceholderView()
                .tabItem {
                    Image(systemName: selectedTab == 2 ? "chart.bar.fill" : "chart.bar")
                    Text("Статистика")
                }
                .tag(2)
            
            // Таб 4: Долги
            DebtListView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "creditcard.fill" : "creditcard")
                    Text("Долги")
                }
                .tag(3)
        }
        .tint(MPColors.accentCoral)
    }
}

// MARK: - Заглушки табов

struct TransactionsPlaceholderView: View {
    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()
            VStack(spacing: MPSpacing.md) {
                Text("📋")
                    .font(.system(size: 60))
                Text("Транзакции")
                    .font(MPTypography.screenTitle)
                    .foregroundColor(MPColors.textPrimary)
                Text("Скоро здесь будет список\nвсех транзакций")
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}



struct StatsPlaceholderView: View {
    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()
            VStack(spacing: MPSpacing.md) {
                Text("📊")
                    .font(.system(size: 60))
                Text("Статистика")
                    .font(MPTypography.screenTitle)
                    .foregroundColor(MPColors.textPrimary)
                Text("Здесь будут графики\nи аналитика")
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}


// MARK: - Preview

#Preview("Светлая тема") {
    MainTabView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self,
            CategoryModel.self,
            CounterpartModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ], inMemory: true)
        .preferredColorScheme(.light)
}

#Preview("Тёмная тема") {
    MainTabView()
        .environmentObject(AppSettings())
        .modelContainer(for: [
            TransactionModel.self,
            CategoryModel.self,
            CounterpartModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ], inMemory: true)
        .preferredColorScheme(.dark)
}
