// MonPapa iOS — Приветственный экран (Onboarding)
//
// Показывается один раз при первом запуске приложения.
// Мотивирует пользователя авторизоваться сразу, чтобы избежать
// конфликтов категорий при последующей синхронизации.
//
// Флаг hasCompletedOnboarding хранится в @AppStorage.

import SwiftUI

struct WelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject private var auth = AuthService.shared
    
    /// Вызывается когда пользователь нажал «Продолжить» или авторизовался
    var onComplete: () -> Void
    
    @State private var showAuth = false
    @State private var currentFeature = 0
    
    private let features: [(icon: String, title: String, subtitle: String)] = [
        ("brain.head.profile.fill", "AI-парсинг", "Просто скажите или напишите\n«Купил кофе 200 руб» — AI всё поймёт"),
        ("arrow.triangle.2.circlepath.circle.fill", "Синхронизация", "Данные на всех устройствах.\nВойдите — и ничего не потеряется"),
        ("chart.pie.fill", "Аналитика", "Понятная статистика расходов\nи доходов в реальном времени"),
    ]
    
    var body: some View {
        ZStack {
            // Фон
            ConfettiBackground(particleCount: 25)
            
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 60)
                
                // MARK: - Логотип
                logoSection
                
                Spacer()
                    .frame(height: 40)
                
                // MARK: - Карусель фич
                featureCarousel
                
                Spacer()
                
                // MARK: - Кнопки
                actionButtons
                
                Spacer()
                    .frame(height: 40)
            }
            .padding(.horizontal, MPSpacing.lg)
        }
        .sheet(isPresented: $showAuth) {
            AuthCoverView()
        }
        .onChange(of: auth.isAuthenticated) { _, newValue in
            print("[WelcomeView] 🔄 auth.isAuthenticated changed → \(newValue)")
            if newValue {
                // Авторизация прошла → запускаем синхронизацию и завершаем onboarding
                print("[WelcomeView] ✅ Авторизация завершена, запуск синхронизации")
                Task {
                    await syncService.sync()
                }
                onComplete()
            }
        }
    }
    
    // MARK: - Логотип
    
    private var logoSection: some View {
        VStack(spacing: MPSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [
                                MPColors.accentYellow.opacity(0.3),
                                MPColors.accentCoral.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                VStack(spacing: -4) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 36))
                        .foregroundColor(MPColors.accentYellow)
                    
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 18))
                        .foregroundColor(MPColors.accentCoral)
                }
            }
            
            Text("MonPapa")
                .font(MPTypography.appTitle)
                .foregroundColor(MPColors.textPrimary)
            
            Text("Семейные финансы под контролем AI")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Карусель фич
    
    private var featureCarousel: some View {
        VStack(spacing: MPSpacing.md) {
            TabView(selection: $currentFeature) {
                ForEach(0..<features.count, id: \.self) { index in
                    featureCard(features[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 160)
            .animation(.easeInOut, value: currentFeature)
            
            // Индикаторы
            HStack(spacing: 8) {
                ForEach(0..<features.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentFeature
                              ? MPColors.accentCoral
                              : MPColors.textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(index == currentFeature ? 1.2 : 1.0)
                        .animation(.spring(response: 0.3), value: currentFeature)
                }
            }
        }
        .task {
            // Автоматическая прокрутка каждые 4 секунды
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { break }
                withAnimation {
                    currentFeature = (currentFeature + 1) % features.count
                }
            }
        }
    }
    
    private func featureCard(_ feature: (icon: String, title: String, subtitle: String)) -> some View {
        VStack(spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(
                        colors: [MPColors.accentYellow, MPColors.accentCoral],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text(feature.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)
            
            Text(feature.subtitle)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundColor(MPColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, MPSpacing.md)
    }
    
    // MARK: - Кнопки действий
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Основная кнопка — авторизация
            Button {
                showAuth = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Войти по Email")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [MPColors.accentCoral, MPColors.accentCoral.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(MPCornerRadius.pill)
                .shadow(color: MPColors.accentCoral.opacity(0.3), radius: 8, y: 4)
            }
            
            // Вторичная кнопка — пропустить
            Button {
                onComplete()
            } label: {
                Text("Продолжить без входа")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            
            // Подсказка
            Text("Войдите, чтобы синхронизировать данные\nмежду устройствами и не потерять их")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(MPColors.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
    }
}

// MARK: - Preview

#Preview("Светлая") {
    WelcomeView(onComplete: {})
        .environmentObject(AppSettings())
        .preferredColorScheme(.light)
}

#Preview("Тёмная") {
    WelcomeView(onComplete: {})
        .environmentObject(AppSettings())
        .preferredColorScheme(.dark)
}
