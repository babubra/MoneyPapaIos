
//  LoginView.swift
//  Monpapa
//
//  Экран входа в приложение MonPapa
//

import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Декоративный фон с конфетти
            ConfettiBackground(particleCount: 35)
            
            // Основной контент
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: MPSpacing.xxl)
                
                // MARK: - Логотип
                logoSection
                
                Spacer()
                    .frame(height: MPSpacing.xl)
                
                // MARK: - Форма входа
                loginForm
                
                Spacer()
                
                // MARK: - Ссылки внизу
                bottomLinks
                
                Spacer()
                    .frame(height: MPSpacing.lg)
            }
            .padding(.horizontal, MPSpacing.lg)
        }
    }
    
    // MARK: - Логотип и название
    
    private var logoSection: some View {
        VStack(spacing: MPSpacing.xs) {
            // Заглушка логотипа — домик + свинка
            ZStack {
                RoundedRectangle(cornerRadius: 20)
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
            
            // Название
            Text("MonPapa")
                .font(MPTypography.appTitle)
                .foregroundColor(MPColors.textPrimary)
            
            // Подзаголовок
            Text("Семейные финансы")
                .font(MPTypography.subtitle)
                .foregroundColor(MPColors.textSecondary)
        }
    }
    
    // MARK: - Форма входа
    
    private var loginForm: some View {
        VStack(spacing: MPSpacing.md) {
            // Поле email
            MPTextField(
                label: "Email",
                placeholder: "Электронная почта",
                icon: "envelope.fill",
                text: $email
            )
            
            // Кнопка «Войти по электронной почте»
            MPButton("Войти по электронной почте", style: .primary) {
                // TODO: Авторизация по email
            }
            
            // Разделитель «или»
            orSeparator
            
            // Кнопка Apple Sign In
            MPAppleSignInButton {
                // TODO: Авторизация через Apple
            }
        }
    }
    
    // MARK: - Разделитель «или»
    
    private var orSeparator: some View {
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
    }
    
    // MARK: - Ссылки внизу
    
    private var bottomLinks: some View {
        HStack(spacing: MPSpacing.lg) {
            Button {
                // TODO: Забыли пароль
            } label: {
                Text("Забыли пароль?")
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textSecondary)
            }
            
            Button {
                // TODO: Регистрация
            } label: {
                Text("Регистрация")
                    .font(MPTypography.captionBold)
                    .foregroundColor(MPColors.textPrimary)
                    .underline()
            }
        }
    }
}

// MARK: - Preview

#Preview("Светлая тема") {
    LoginView()
        .preferredColorScheme(.light)
}

#Preview("Тёмная тема") {
    LoginView()
        .preferredColorScheme(.dark)
}
