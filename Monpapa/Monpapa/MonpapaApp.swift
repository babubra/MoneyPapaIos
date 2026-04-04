//
//  MonpapaApp.swift
//  Monpapa
//
//  Created by fatau on 22.03.2026.
//

import SwiftUI
import SwiftData

@main
struct MonpapaApp: App {
    @StateObject private var settings = AppSettings()
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CategoryModel.self,
            CounterpartModel.self,
            TransactionModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(settings.preferredColorScheme)
                .environmentObject(settings)
                .onAppear {
                    SeedData.seedIfNeeded(context: sharedModelContainer.mainContext)
                }
                .task {
                    // Авторизуем устройство при запуске (получаем Bearer-токен для AI)
                    await AIService.shared.authenticateIfNeeded()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
