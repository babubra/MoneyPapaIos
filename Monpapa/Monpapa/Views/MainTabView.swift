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
            StatsView()
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
