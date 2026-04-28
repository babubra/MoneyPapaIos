
//  MPTextField.swift
//  Monpapa
//
//  Поле ввода дизайн-системы MonPapa
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct MPTextField: View {
    let label: String
    let placeholder: String
    let icon: String
    @Binding var text: String
    
    #if os(iOS)
    var keyboardType: UIKeyboardType = .default
    #endif
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Лейбл сверху (внутри карточки)
            if !text.isEmpty || isFocused {
                Text(LocalizedStringKey(label))
                    .font(MPTypography.inputLabel)
                    .foregroundColor(MPColors.accentYellow)
                    .padding(.leading, 44)
                    .padding(.top, MPSpacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Поле ввода с иконкой
            HStack(spacing: MPSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(MPColors.accentYellow)
                    .frame(width: 24)
                
                textField
            }
            .padding(.horizontal, MPSpacing.md)
            .padding(.vertical, text.isEmpty && !isFocused ? MPSpacing.md : MPSpacing.xs)
            .padding(.bottom, text.isEmpty && !isFocused ? 0 : MPSpacing.xs)
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.pill)
        .overlay(
            RoundedRectangle(cornerRadius: MPCornerRadius.pill)
                .stroke(
                    isFocused ? MPColors.accentYellow : MPColors.accentYellow.opacity(0.5),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
    }
    
    @ViewBuilder
    private var textField: some View {
        #if os(iOS)
        TextField(LocalizedStringKey(placeholder), text: $text)
            .font(MPTypography.input)
            .foregroundColor(MPColors.textPrimary)
            .keyboardType(keyboardType)
            .focused($isFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        TextField(LocalizedStringKey(placeholder), text: $text)
            .font(MPTypography.input)
            .foregroundColor(MPColors.textPrimary)
            .focused($isFocused)
            .autocorrectionDisabled()
        #endif
    }
}

// MARK: - Preview

#Preview("Поле ввода") {
    struct PreviewWrapper: View {
        @State private var email = ""
        @State private var filledEmail = "user@example.com"
        
        var body: some View {
            VStack(spacing: MPSpacing.md) {
                MPTextField(
                    label: "Email",
                    placeholder: "Электронная почта",
                    icon: "envelope.fill",
                    text: $email
                )
                
                MPTextField(
                    label: "Email",
                    placeholder: "Электронная почта",
                    icon: "envelope.fill",
                    text: $filledEmail
                )
            }
            .padding(MPSpacing.lg)
            .background(MPColors.background)
        }
    }
    
    return PreviewWrapper()
}
