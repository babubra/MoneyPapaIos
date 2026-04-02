// MonPapa iOS — AI Input Bar (Telegram-style ввод транзакций)
// Анимированные состояния: idle → recording → sending → idle

import SwiftUI

// MARK: - Состояния кнопок

enum AIInputState {
    case idle       // Две кнопки: 🎤 и ➡️
    case recording  // Запись голоса: одна пульсирующая кнопка
    case sending    // Отправка/парсинг: спиннер
}

struct AIInputBar: View {
    @Binding var text: String
    var onSend: (String) -> Void
    var onVoiceResult: (String) -> Void
    
    @State private var state: AIInputState = .idle
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6
    
    @Namespace private var buttonAnimation
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(alignment: .bottom, spacing: MPSpacing.xs) {
            // Поле ввода текста (скрывается при записи)
            if state != .recording {
                TextField("Потратил 500 на обед...", text: $text, axis: .vertical)
                    .font(MPTypography.input)
                    .foregroundColor(MPColors.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.vertical, MPSpacing.sm)
                    .background(MPColors.cardBackground)
                    .cornerRadius(MPCornerRadius.lg)
                    .overlay(
                        RoundedRectangle(cornerRadius: MPCornerRadius.lg)
                            .stroke(MPColors.separator, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .disabled(state == .sending)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            // Текст "Слушаю..." при записи
            if state == .recording {
                HStack(spacing: MPSpacing.sm) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulseOpacity)
                    
                    Text("Слушаю...")
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MPSpacing.md)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            // MARK: - Кнопки
            
            switch state {
            case .idle:
                // Кнопка микрофона
                Button(action: startRecording) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(MPColors.accentCoral)
                        .clipShape(Circle())
                        .matchedGeometryEffect(id: "actionButton", in: buttonAnimation)
                }
                .transition(.scale.combined(with: .opacity))
                
                // Кнопка отправки
                Button(action: sendText) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? MPColors.accentCoral.opacity(0.4)
                                : MPColors.accentCoral
                        )
                        .clipShape(Circle())
                        .matchedGeometryEffect(id: "sendButton", in: buttonAnimation)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .transition(.scale.combined(with: .opacity))
                
            case .recording:
                // Кнопка отмены записи
                Button(action: cancelRecording) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(MPColors.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(MPColors.cardBackground)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(MPColors.separator, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "actionButton", in: buttonAnimation)
                }
                .transition(.scale.combined(with: .opacity))
                
                // Пульсирующая кнопка «Отправить запись»
                Button(action: stopRecording) {
                    ZStack {
                        // Пульсирующие кольца
                        Circle()
                            .stroke(MPColors.accentCoral.opacity(0.3), lineWidth: 2)
                            .frame(width: 40, height: 40)
                            .scaleEffect(pulseScale)
                            .opacity(2.0 - Double(pulseScale))
                        
                        Circle()
                            .stroke(MPColors.accentCoral.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 40, height: 40)
                            .scaleEffect(pulseScale * 0.8 + 0.4)
                            .opacity(2.0 - Double(pulseScale))
                        
                        // Основная кнопка
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(MPColors.accentCoral)
                            .clipShape(Circle())
                            .matchedGeometryEffect(id: "sendButton", in: buttonAnimation)
                    }
                    .frame(width: 56, height: 56)
                }
                .transition(.scale.combined(with: .opacity))
                
            case .sending:
                // Спиннер загрузки
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .frame(width: 40, height: 40)
                    .background(MPColors.accentCoral.opacity(0.7))
                    .clipShape(Circle())
                    .matchedGeometryEffect(id: "sendButton", in: buttonAnimation)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.xs)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
    }
    
    // MARK: - Actions
    
    private func sendText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isFocused = false
        
        withAnimation { state = .sending }
        
        // TODO: Заменить на реальный AI-парсинг
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            onSend(trimmed)
            text = ""
            withAnimation { state = .idle }
        }
    }
    
    private func startRecording() {
        withAnimation { state = .recording }
        startPulseAnimation()
        // TODO: Начать запись через AVAudioRecorder
    }
    
    private func stopRecording() {
        withAnimation { state = .sending }
        stopPulseAnimation()
        
        // TODO: Заменить на реальное распознавание речи
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            onVoiceResult("Потратил 350 на такси")
            withAnimation { state = .idle }
        }
    }
    
    private func cancelRecording() {
        stopPulseAnimation()
        // TODO: Остановить AVAudioRecorder без отправки
        withAnimation { state = .idle }
    }
    
    // MARK: - Пульсация
    
    private func startPulseAnimation() {
        withAnimation(
            .easeInOut(duration: 1.0)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.8
            pulseOpacity = 0.2
        }
    }
    
    private func stopPulseAnimation() {
        withAnimation(.easeOut(duration: 0.3)) {
            pulseScale = 1.0
            pulseOpacity = 0.6
        }
    }
}

// MARK: - Preview

#Preview("AI Input Bar") {
    struct PreviewWrapper: View {
        @State private var text = ""
        
        var body: some View {
            VStack {
                Spacer()
                
                Text("Состояние: idle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                AIInputBar(
                    text: $text,
                    onSend: { msg in print("Отправлено: \(msg)") },
                    onVoiceResult: { msg in print("Голос: \(msg)") }
                )
            }
            .background(MPColors.background)
        }
    }
    
    return PreviewWrapper()
}
