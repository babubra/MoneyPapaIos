// MonPapa iOS — AI Input Bar (Telegram-style ввод транзакций)
// Анимированные состояния: idle → recording → sending → idle
// Интегрирован AudioRecorderService для голосового ввода

import SwiftUI

// MARK: - Состояния кнопок

enum AIInputState {
    case idle       // Две кнопки: 🎤 и ➡️
    case recording  // Запись голоса: таймер + кнопки
    case sending    // Отправка/парсинг: спиннер
}

struct AIInputBar: View {
    @Binding var text: String
    /// Существующие категории для передачи в AI
    var categories: [AICategoryDTO]
    /// Вызывается после успешного AI-парсинга текста
    var onParseResult: (AiParseResult) -> Void
    /// Вызывается после успешного AI-парсинга голоса
    var onVoiceResult: (AiParseResult) -> Void
    /// Вызывается при ошибке (для показа снэкбара/алерта)
    var onError: ((String) -> Void)?

    private var aiService: AIService { AIService.shared }

    @State private var state: AIInputState = .idle
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6
    @State private var audioRecorder = AudioRecorderService()
    @State private var showMicPermissionAlert = false

    @Namespace private var buttonAnimation
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Индикатор VAD-статуса при записи
            if state == .recording {
                recordingStatusBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
                
                // Текст при записи
                if state == .recording {
                    HStack(spacing: MPSpacing.sm) {
                        // Пульсирующий индикатор записи
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(pulseOpacity)
                        
                        Text(audioRecorder.formattedDuration)
                            .font(.system(size: 17, weight: .medium, design: .monospaced))
                            .foregroundColor(MPColors.textPrimary)

                        // Визуализация уровня звука
                        audioLevelIndicator
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
                    Button(action: stopAndSend) {
                        ZStack {
                            // Пульсирующие кольца (привязаны к уровню звука)
                            Circle()
                                .stroke(MPColors.accentCoral.opacity(0.3), lineWidth: 2)
                                .frame(width: 40, height: 40)
                                .scaleEffect(1.0 + CGFloat(audioRecorder.audioLevel) * 0.8)
                                .opacity(1.0 - Double(audioRecorder.audioLevel) * 0.5)
                            
                            Circle()
                                .stroke(MPColors.accentCoral.opacity(0.2), lineWidth: 1.5)
                                .frame(width: 40, height: 40)
                                .scaleEffect(1.0 + CGFloat(audioRecorder.audioLevel) * 0.5)
                                .opacity(1.0 - Double(audioRecorder.audioLevel) * 0.3)
                            
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
        .alert("Доступ к микрофону", isPresented: $showMicPermissionAlert) {
            Button("Открыть Настройки") {
                audioRecorder.openSettings()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Для голосового ввода транзакций нужен доступ к микрофону. Включите его в Настройках → MonPapa → Микрофон.")
        }
        .onAppear {
            setupRecorderCallbacks()
        }
    }

    // MARK: - Визуализация уровня звука

    private var audioLevelIndicator: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: i))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: audioRecorder.audioLevel)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index) / 12.0
        let active = audioRecorder.audioLevel > threshold
        return active ? CGFloat(8 + index * 1) : 4
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / 12.0
        if audioRecorder.audioLevel > threshold {
            return index < 8 ? MPColors.accentCoral : Color.red
        }
        return MPColors.separator
    }

    // MARK: - Статус-бар записи

    private var recordingStatusBar: some View {
        HStack(spacing: MPSpacing.xs) {
            if audioRecorder.recordingDuration > 25 {
                // Предупреждение о скором лимите
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("Лимит \(30 - Int(audioRecorder.recordingDuration)) сек")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, audioRecorder.recordingDuration > 25 ? 4 : 0)
    }

    // MARK: - Recorder Callbacks

    private func setupRecorderCallbacks() {
        audioRecorder.onAutoStop = { fileURL, reason in
            // Автостоп: отправляем файл
            sendAudioFile(fileURL)
        }

        audioRecorder.onError = { reason in
            withAnimation { state = .idle }
            switch reason {
            case .silenceTimeout:
                onError?("Я вас не слышу. Попробуйте ещё раз.")
            case .error(let message):
                onError?(message)
            default:
                break
            }
        }
    }
    
    // MARK: - Actions

    private func sendText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isFocused = false
        withAnimation { state = .sending }

        Task {
            defer { withAnimation { state = .idle } }
            do {
                let result = try await aiService.parseText(trimmed, categories: categories)
                text = ""
                onParseResult(result)
            } catch AIServiceError.rateLimitExceeded {
                onError?("Достигнут дневной лимит AI-запросов")
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    private func startRecording() {
        Task {
            let granted = await audioRecorder.startRecording()
            if granted {
                withAnimation { state = .recording }
                startPulseAnimation()
            } else {
                // Нет разрешения → показать алерт со ссылкой на настройки
                showMicPermissionAlert = true
            }
        }
    }

    private func stopAndSend() {
        stopPulseAnimation()
        guard let fileURL = audioRecorder.stopRecording() else {
            withAnimation { state = .idle }
            onError?("Не удалось получить запись")
            return
        }
        sendAudioFile(fileURL)
    }

    private func sendAudioFile(_ fileURL: URL) {
        withAnimation { state = .sending }
        stopPulseAnimation()

        Task {
            defer {
                audioRecorder.reset()
                // Удаляем временный файл
                try? FileManager.default.removeItem(at: fileURL)
            }
            do {
                let result = try await aiService.parseAudio(fileURL: fileURL, categories: categories)
                withAnimation { state = .idle }
                onVoiceResult(result)
            } catch AIServiceError.rateLimitExceeded {
                withAnimation { state = .idle }
                onError?("Превышен лимит аудио-запросов. Попробуйте позже.")
            } catch {
                withAnimation { state = .idle }
                onError?(error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        audioRecorder.cancelRecording()
        stopPulseAnimation()
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
                    categories: [],
                    onParseResult: { result in print("AI результат: \(result.status), \(result.amount ?? 0) \(result.currency ?? "")") },
                    onVoiceResult: { result in print("Голос: \(result.status)") },
                    onError: { error in print("Ошибка: \(error)") }
                )
            }
            .background(MPColors.background)
        }
    }
    
    return PreviewWrapper()
}
