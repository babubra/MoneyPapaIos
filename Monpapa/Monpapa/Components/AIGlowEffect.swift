// MonPapa iOS — AI Visual Effects
// Animated border glow + Shimmer badge для AI-созданных транзакций
// Вдохновлено Apple Intelligence UI

import SwiftUI

// MARK: - AI Gradient Colors (Apple Intelligence palette)

private enum AIColors {
    static let gradientColors: [Color] = [
        Color(red: 0.55, green: 0.35, blue: 0.95),  // Фиолетовый
        Color(red: 0.30, green: 0.55, blue: 1.00),  // Голубой
        Color(red: 0.95, green: 0.40, blue: 0.65),  // Розовый
        Color(red: 0.55, green: 0.35, blue: 0.95),  // Фиолетовый (замыкание)
    ]

    static let shimmerColors: [Color] = [
        .white.opacity(0.0),
        .white.opacity(0.5),
        .white.opacity(0.0),
    ]
}

// MARK: - 1. Animated Border Glow

/// Пульсирующий glow-контур вокруг View, как у Apple Intelligence.
/// Используется для визуального выделения AI-заполненных полей.
struct AIBorderGlow: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let lineWidth: CGFloat

    @State private var rotation: Double = 0
    @State private var glowOpacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        AngularGradient(
                            colors: AIColors.gradientColors,
                            center: .center,
                            startAngle: .degrees(rotation),
                            endAngle: .degrees(rotation + 360)
                        ),
                        lineWidth: isActive ? lineWidth : 0
                    )
                    .opacity(glowOpacity)
                    .blur(radius: 1)
            )
            // Внешнее свечение (glow)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        AngularGradient(
                            colors: AIColors.gradientColors,
                            center: .center,
                            startAngle: .degrees(rotation),
                            endAngle: .degrees(rotation + 360)
                        ),
                        lineWidth: isActive ? lineWidth * 4 : 0
                    )
                    .opacity(glowOpacity * 0.6)
                    .blur(radius: 16)
            )
            .onChange(of: isActive) { _, active in
                if active {
                    startGlow()
                } else {
                    stopGlow()
                }
            }
            .onAppear {
                if isActive {
                    startGlow()
                }
            }
    }

    private func startGlow() {
        glowOpacity = 1.0

        // Бесконечная ротация градиента
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }

    private func stopGlow() {
        withAnimation(.easeOut(duration: 0.5)) {
            glowOpacity = 0
        }
    }
}

extension View {
    /// Добавляет анимированный AI glow-контур вокруг View
    func aiBorderGlow(
        isActive: Bool,
        cornerRadius: CGFloat = MPCornerRadius.lg,
        lineWidth: CGFloat = 2
    ) -> some View {
        modifier(AIBorderGlow(
            isActive: isActive,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth
        ))
    }
}

// MARK: - 2. Shimmer Badge "✨ AI"

/// Бейдж "✨ AI" с переливающимся shimmer-эффектом.
/// Показывается в navigation bar когда транзакция создана через AI.
struct AIShimmerBadge: View {
    @State private var animationOffset: CGFloat = -1.0

    var body: some View {
        Text("✨ AI")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                ZStack {
                    // Базовый градиент
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.35, blue: 0.95),
                            Color(red: 0.30, green: 0.55, blue: 1.00),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    // Shimmer overlay
                    LinearGradient(
                        colors: AIColors.shimmerColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: animationOffset * 60)
                }
            )
            .clipShape(Capsule())
            .onAppear {
                withAnimation(
                    .linear(duration: 2.0)
                    .repeatForever(autoreverses: false)
                ) {
                    animationOffset = 1.0
                }
            }
    }
}

// MARK: - 3. AI Banner

/// Баннер "AI распознал вашу транзакцию" с glow-фоном
struct AIResultBanner: View {
    let status: AiParseStatus
    let isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: status == .ok ? "sparkles" : "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold))

                Text(status == .ok
                     ? "AI распознал транзакцию"
                     : "Уточните недостающие данные")
                    .font(.system(size: 14, weight: .medium, design: .rounded))

                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: status == .ok
                        ? [Color(red: 0.55, green: 0.35, blue: 0.95).opacity(0.85),
                           Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.85)]
                        : [Color.orange.opacity(0.85), Color.orange.opacity(0.6)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(MPCornerRadius.md)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Preview

#Preview("AI Glow Effects") {
    VStack(spacing: 30) {
        // Badge
        AIShimmerBadge()

        // Banner OK
        AIResultBanner(status: .ok, isVisible: true)

        // Banner Incomplete
        AIResultBanner(status: .incomplete, isVisible: true)

        // Glow on amount field
        VStack(spacing: 4) {
            Text("500 ₽")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
        .aiBorderGlow(isActive: true)
        .padding(.horizontal, 20)
    }
    .padding()
    .background(MPColors.background)
    .preferredColorScheme(.dark)
}
