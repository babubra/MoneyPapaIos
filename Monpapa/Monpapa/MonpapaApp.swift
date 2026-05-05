//
//  MonpapaApp.swift
//  Monpapa
//
//  Created by fatau on 22.03.2026.
//
//  Auth Model C: вход в приложение защищён обязательной авторизацией.
//  Без валидного JWT в Keychain показывается OnboardingView (Welcome + auth);
//  после успешного входа auth.isAuthenticated → true → MainTabView.
//
//  TODO для production:
//    1. Создать Monpapa.entitlements с ключом com.apple.developer.applesignin
//       (Personal Team Xcode не выдаёт — нужен Apple Developer Program $99/год).
//    2. Зарегистрировать Bundle ID `fatau.Monpapa` на developer.apple.com и
//       включить capability "Sign in with Apple".
//    3. Без entitlement Apple Sign-In падает в runtime — UI показывает friendly
//       fallback "Войдите по Email" (см. AuthService.AuthError.appleSignInUnavailable).
//

import SwiftUI
import SwiftData

@main
struct MonpapaApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var syncService: SyncService
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @Environment(\.scenePhase) private var scenePhase

    let sharedModelContainer: ModelContainer

    init() {
        // Применяем выбранный язык ДО инициализации UI,
        // чтобы системные бандлы подхватили правильный .lproj
        LocalizationManager.applyAtLaunch()

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
            Group {
                if auth.isAuthenticated {
                    MainTabView()
                } else {
                    // OnboardingView — теперь это welcome + обязательный auth-gate.
                    // onComplete остаётся для backward-compat, но фактически переход
                    // происходит автоматически через onChange(auth.isAuthenticated).
                    OnboardingView { }
                }
            }
            .preferredColorScheme(settings.preferredColorScheme)
            .environment(\.locale, LocalizationManager.effectiveLocale())
            .environmentObject(settings)
            .environmentObject(syncService)
            .environmentObject(subscription)
            .onAppear {
                SeedData.seedIfNeeded(context: sharedModelContainer.mainContext)
            }
            .onChange(of: auth.isAuthenticated) { _, isLoggedIn in
                // Сразу после логина — подтягиваем актуальный subscription_status
                // и AI trial counter, чтобы Dashboard и Settings показали их без задержки.
                if isLoggedIn {
                    Task { await subscription.refreshStatus() }
                }
            }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && auth.isAuthenticated {
                Task {
                    await syncService.sync()
                    await subscription.refreshStatus()
                }
            }
        }
    }
}
