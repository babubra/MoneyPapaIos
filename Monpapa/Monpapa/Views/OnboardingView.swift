//
//  OnboardingView.swift
//  Monpapa
//
//  Полноэкранный пошаговый онбординг при первом запуске.
//
//  Страницы:
//    1. Приветствие — знакомство с приложением
//    2. Голосовой ввод — AI-парсинг транзакций
//    3. Безопасность — авторизация и синхронизация
//    4. Форма авторизации — email / Apple / пропуск
//
//  Изображения:
//    Добавьте картинки в Assets.xcassets с именами:
//      - onboarding_welcome   (страница 1)
//      - onboarding_voice     (страница 2)
//      - onboarding_security  (страница 3)
//
//    Рекомендуемые размеры (PNG или JPEG):
//      @1x:  360 × 480 px
//      @2x:  720 × 960 px
//      @3x: 1080 × 1440 px
//    Или один файл Single Scale: 1080 × 1440 px
//

import SwiftUI
import SwiftData

// MARK: - Модель страницы онбординга

private struct OnboardingPageData {
    let imageName: String       // Имя картинки в Assets.xcassets
    let fallbackIcon: String    // SF Symbol если картинки нет
    let iconGradient: [Color]   // Градиент для placeholder-иконки
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
}

// MARK: - OnboardingView

struct OnboardingView: View {
    
    /// Вызывается при завершении онбординга (авторизация или «Продолжить без входа»)
    var onComplete: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject private var auth = AuthService.shared
    
    @State private var currentPage = 0
    @State private var showAuth = false
    
    private let totalPages = 4
    
    /// Данные для страниц 1-3 (страница 4 — авторизация, верстается отдельно)
    private let pages: [OnboardingPageData] = [
        OnboardingPageData(
            imageName: "onboarding_welcome",
            fallbackIcon: "house.fill",
            iconGradient: [MPColors.accentYellow, MPColors.accentCoral],
            title: "Добро пожаловать\nв MonPapa!",
            subtitle: "Приложение для простого и эффективного учёта доходов и расходов. Ничего лишнего — только то, что действительно нужно."
        ),
        OnboardingPageData(
            imageName: "onboarding_voice",
            fallbackIcon: "mic.fill",
            iconGradient: [MPColors.accentCoral, MPColors.accentYellow],
            title: "Создать транзакцию\nпроще простого!",
            subtitle: "Наговорите голосом: «Купил молока за 80 рублей» — AI автоматически предложит категорию и заполнит все поля. Останется только проверить и сохранить!"
        ),
        OnboardingPageData(
            imageName: "onboarding_security",
            fallbackIcon: "lock.shield.fill",
            iconGradient: [MPColors.accentBlue, MPColors.accentGreen],
            title: "Ваши данные\nв безопасности",
            subtitle: "Авторизуйтесь, чтобы сохранить доступ к транзакциям и синхронизировать данные между устройствами."
        ),
    ]
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            // Фон
            MPColors.background.ignoresSafeArea()
            ConfettiBackground(particleCount: 20)
            
            VStack(spacing: 0) {
                // Кнопка «Пропустить» вверху справа
                skipButton
                
                // Страницы
                TabView(selection: $currentPage) {
                    // Страницы 1-3: информационные
                    ForEach(0..<pages.count, id: \.self) { index in
                        contentPage(pages[index])
                            .tag(index)
                    }
                    
                    // Страница 4: авторизация
                    authPage
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                // Нижняя панель: индикаторы + кнопка «Далее»
                bottomControls
                    .padding(.horizontal, MPSpacing.lg)
                    .padding(.bottom, MPSpacing.lg)
            }
        }
        .sheet(isPresented: $showAuth) {
            AuthCoverView()
        }
        .onChange(of: auth.isAuthenticated) { _, newValue in
            if newValue {
                Task { await syncService.sync() }
                onComplete()
            }
        }
    }
    
    // MARK: - Skip Button
    
    private var skipButton: some View {
        HStack {
            Spacer()
            
            if currentPage < totalPages - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        currentPage = totalPages - 1
                    }
                } label: {
                    Text("Пропустить")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, MPSpacing.lg)
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }
    
    // MARK: - Content Page (страницы 1–3)
    
    private func contentPage(_ page: OnboardingPageData) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: MPSpacing.sm)
                
                // Область изображения
                imageArea(page: page)
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.size.height * 0.5)
                    .padding(.horizontal, MPSpacing.xl)
                
                Spacer()
                    .frame(height: MPSpacing.xl)
                
                // Текстовый блок
                VStack(spacing: MPSpacing.sm) {
                    Text(page.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(MPColors.textPrimary)
                        .multilineTextAlignment(.center)
                    
                    Text(page.subtitle)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundColor(MPColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, MPSpacing.lg)
                
                Spacer()
            }
        }
    }
    
    // MARK: - Image Area
    
    @ViewBuilder
    private func imageArea(page: OnboardingPageData) -> some View {
        if UIImage(named: page.imageName) != nil {
            // Реальное изображение из Assets
            Image(page.imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
        } else {
            // Placeholder: gradient-карточка с SF Symbol
            placeholderCard(
                icon: page.fallbackIcon,
                gradient: page.iconGradient
            )
        }
    }
    
    /// Красивый placeholder пока нет реальных изображений
    private func placeholderCard(icon: String, gradient: [Color]) -> some View {
        ZStack {
            // Фоновая карточка с градиентом
            RoundedRectangle(cornerRadius: 28)
                .fill(
                    LinearGradient(
                        colors: [
                            gradient[0].opacity(colorScheme == .dark ? 0.2 : 0.12),
                            gradient[1].opacity(colorScheme == .dark ? 0.1 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    gradient[0].opacity(0.3),
                                    gradient[1].opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
            
            // Декоративные круги на фоне
            Circle()
                .fill(gradient[0].opacity(0.08))
                .frame(width: 180, height: 180)
                .offset(x: -60, y: -40)
            
            Circle()
                .fill(gradient[1].opacity(0.06))
                .frame(width: 120, height: 120)
                .offset(x: 80, y: 60)
            
            // Иконка
            Image(systemName: icon)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
    
    // MARK: - Auth Page (страница 4)
    
    private var authPage: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: MPSpacing.lg)
            
            // Иконка
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                MPColors.accentCoral.opacity(colorScheme == .dark ? 0.2 : 0.12),
                                MPColors.accentYellow.opacity(colorScheme == .dark ? 0.12 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MPColors.accentCoral, MPColors.accentYellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            Spacer()
                .frame(height: MPSpacing.lg)
            
            // Заголовок и описание
            VStack(spacing: MPSpacing.sm) {
                Text("Авторизуйтесь")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
                
                Text("Войдите, чтобы синхронизировать данные\nмежду устройствами и не потерять их")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            
            Spacer()
                .frame(height: MPSpacing.xl)
            
            // Кнопки авторизации
            VStack(spacing: MPSpacing.md) {
                // Войти по Email
                Button {
                    showAuth = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Войти по Email")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [MPColors.accentCoral, MPColors.accentCoral.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(MPCornerRadius.pill)
                    .shadow(color: MPColors.accentCoral.opacity(0.3), radius: 8, y: 4)
                }
                
                // Разделитель «или»
                HStack(spacing: MPSpacing.md) {
                    Rectangle()
                        .fill(MPColors.separator)
                        .frame(height: 1)
                    Text("или")
                        .font(MPTypography.caption)
                        .foregroundColor(MPColors.textSecondary)
                    Rectangle()
                        .fill(MPColors.separator)
                        .frame(height: 1)
                }
                .padding(.vertical, MPSpacing.xs)
                
                // Apple Sign In
                MPAppleSignInButton {
                    // TODO: Авторизация через Apple
                }
            }
            .padding(.horizontal, MPSpacing.lg)
            
            Spacer()
            
            // Продолжить без входа
            Button {
                onComplete()
            } label: {
                Text("Продолжить без входа")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
            .padding(.bottom, MPSpacing.xs)
        }
    }
    
    // MARK: - Bottom Controls (индикаторы + кнопка)
    
    private var bottomControls: some View {
        VStack(spacing: MPSpacing.md) {
            // Индикаторы страниц (capsule-стиль)
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(
                            index == currentPage
                                ? MPColors.accentCoral
                                : MPColors.textSecondary.opacity(0.3)
                        )
                        .frame(
                            width: index == currentPage ? 24 : 8,
                            height: 8
                        )
                        .animation(.spring(response: 0.3), value: currentPage)
                }
            }
            
            // Кнопка «Далее» (только на страницах 1-3)
            if currentPage < totalPages - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage += 1
                    }
                } label: {
                    Text("Далее")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [MPColors.accentCoral, MPColors.accentCoral.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(MPCornerRadius.pill)
                        .shadow(color: MPColors.accentCoral.opacity(0.3), radius: 8, y: 4)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }
}

// MARK: - Preview

#Preview("Онбординг — Светлая") {
    let container = try! ModelContainer(
        for: CategoryModel.self, TransactionModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    OnboardingView(onComplete: {})
        .environmentObject(AppSettings())
        .environmentObject(SyncService(modelContext: container.mainContext))
        .modelContainer(container)
        .preferredColorScheme(.light)
}

#Preview("Онбординг — Тёмная") {
    let container = try! ModelContainer(
        for: CategoryModel.self, TransactionModel.self, CounterpartModel.self, DebtModel.self, DebtPaymentModel.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    OnboardingView(onComplete: {})
        .environmentObject(AppSettings())
        .environmentObject(SyncService(modelContext: container.mainContext))
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
