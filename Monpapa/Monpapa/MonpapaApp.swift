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
    @StateObject private var syncService: SyncService
    @Environment(\.scenePhase) private var scenePhase
    
    let sharedModelContainer: ModelContainer
    
    init() {
        let schema = Schema([
            CategoryModel.self,
            CounterpartModel.self,
            TransactionModel.self,
            DebtModel.self,
            DebtPaymentModel.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.sharedModelContainer = container
            _syncService = StateObject(wrappedValue: SyncService(modelContext: container.mainContext))
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(settings.preferredColorScheme)
                .environmentObject(settings)
                .environmentObject(syncService)
                .onAppear {
                    SeedData.seedIfNeeded(context: sharedModelContainer.mainContext)
                }
                .task {
                    // Авторизуем устройство при запуске (получаем Bearer-токен для AI)
                    await AIService.shared.authenticateIfNeeded()
                }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                if AuthService.shared.isAuthenticated {
                    Task {
                        await syncService.sync()
                    }
                }
            }
        }
    }
}
