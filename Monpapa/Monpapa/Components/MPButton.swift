
//  MPButton.swift
//  Monpapa
//
//  Переиспользуемая кнопка дизайн-системы MonPapa
//

import SwiftUI
import AuthenticationServices

// MARK: - Варианты кнопки

enum MPButtonStyle {
    /// Основная кнопка действия — коралловый фон, белый текст
    case primary
    /// Вторичная кнопка — прозрачный фон, цветной бордер
    case secondary
    /// Текстовая кнопка-ссылка
    case text
}

// MARK: - MPButton

struct MPButton: View {
    let title: String
    let style: MPButtonStyle
    let icon: String?
    let action: () -> Void
    
    init(
        _ title: String,
        style: MPButtonStyle = .primary,
        icon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.icon = icon
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: MPSpacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                }
                Text(title)
                    .font(style == .text ? MPTypography.caption : MPTypography.button)
            }
            .frame(maxWidth: style == .text ? nil : .infinity)
            .frame(height: style == .text ? nil : 52)
            .foregroundColor(foregroundColor)
            .background(backgroundColor)
            .cornerRadius(MPCornerRadius.pill)
            .overlay(
                RoundedRectangle(cornerRadius: MPCornerRadius.pill)
                    .stroke(borderColor, lineWidth: style == .secondary ? 1.5 : 0)
            )
        }
    }
    
    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary:
            return MPColors.accentCoral
        case .text:
            return MPColors.textSecondary
        }
    }
    
    private var backgroundColor: Color {
        switch style {
        case .primary:
            return MPColors.accentCoral
        case .secondary, .text:
            return .clear
        }
    }
    
    private var borderColor: Color {
        switch style {
        case .secondary:
            return MPColors.accentCoral
        default:
            return .clear
        }
    }
}

// MARK: - Apple Sign In кнопка

struct MPAppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: MPSpacing.xs) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 18))
                Text("Войти с помощью Apple")
                    .font(MPTypography.button)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundColor(colorScheme == .dark ? .black : .white)
            .background(colorScheme == .dark ? Color.white : Color.black)
            .cornerRadius(MPCornerRadius.pill)
        }
    }
}

// MARK: - Previews

#Preview("Кнопки") {
    VStack(spacing: MPSpacing.md) {
        MPButton("Войти по электронной почте", style: .primary) {}
        MPButton("Вторичная кнопка", style: .secondary) {}
        MPAppleSignInButton {}
        
        HStack {
            MPButton("Забыли пароль?", style: .text) {}
            MPButton("Регистрация", style: .text) {}
        }
    }
    .padding(MPSpacing.lg)
    .background(MPColors.background)
}
