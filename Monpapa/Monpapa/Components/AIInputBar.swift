// MonPapa iOS — AI Input Bar (Telegram-style ввод транзакций)
// Анимированные состояния: idle → recording → sending → idle
// Интегрирован AudioRecorderService для голосового ввода

import SwiftUI
import Combine

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
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentHintIndex = 0
    
    private let aiHints = [
        "Купил хлеб 150 рублей",
        "Потратил 2000 на поход в кафе",
        "Купил кофе на заправке. Выбери категорию Еда вне дома с родительской Еда",
        "Получил 50 000 рублей премию. Запиши в категорию Зарплата.",
        "Потратил 3000 на бензин.",
        "Купил товаров для дома на 4500. Запиши в категорию Товары для дома."
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Индикатор VAD-статуса при записи
            if state == .recording {
                recordingStatusBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if state == .recording {
                // MARK: - Состояние записи (полностью заменяет текстовое поле)
                HStack(spacing: MPSpacing.md) {
                    // Кнопка отмены записи
                    Button(action: cancelRecording) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(MPColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(MPColors.cardBackground)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(MPColors.separator, lineWidth: 1))
                            .matchedGeometryEffect(id: "cancelButton", in: buttonAnimation)
                    }
                    .transition(.scale.combined(with: .opacity))
                    
                    // Таймер + Звуковая волна (по центру)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(pulseOpacity)
                        
                        Text(audioRecorder.formattedDuration)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            
                        AIAudioWaveformView(audioLevel: audioRecorder.audioLevel)
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Пульсирующая кнопка «Отправить запись»
                    Button(action: stopAndSend) {
                        ZStack {
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
                            
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(MPColors.accentCoral)
                                .clipShape(Circle())
                                .matchedGeometryEffect(id: "actionButton", in: buttonAnimation)
                        }
                        .frame(width: 40, height: 40)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.vertical, MPSpacing.sm)
                .background(MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.lg)
                .overlay(
                    RoundedRectangle(cornerRadius: MPCornerRadius.lg)
                        .stroke(AIColors.gradientColors[1].opacity(0.5), lineWidth: 1)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                
            } else {
                // MARK: - Состояние ввода текста (.idle и .sending)
                ZStack(alignment: .bottomTrailing) {
                    
                    ZStack(alignment: .topLeading) {
                        // Само поле ввода
                        TextField("", text: $text, axis: .vertical)
                            .font(MPTypography.input)
                            .foregroundColor(MPColors.textPrimary)
                            .lineLimit(3...5) // Резервируем место под 3 строки сразу
                            .padding(.leading, MPSpacing.md)
                            .padding(.trailing, 52) // Место под кнопку справа
                            .padding(.top, MPSpacing.sm)
                            .padding(.bottom, 16)
                            .frame(minHeight: 80) // Фиксированная минимальная высота для длинных подсказок
                            .disabled(state == .sending)
                        
                        // Анимированный плейсхолдер
                        if text.isEmpty {
                            Text(aiHints[currentHintIndex])
                                .font(MPTypography.input)
                                .foregroundColor(colorScheme == .dark ? .white.opacity(0.3) : .black.opacity(0.3))
                                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .top)).combined(with: .opacity))
                                .id(currentHintIndex)
                                .padding(.leading, MPSpacing.md)
                                .padding(.trailing, 52)
                                .padding(.top, MPSpacing.sm)
                                .allowsHitTesting(false)
                        }
                    }
                    
                    // КНОПКА внутри текстового поля
                    Group {
                        if state == .sending {
                            // Спиннер загрузки
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .frame(width: 40, height: 40)
                                .background(MPColors.accentCoral.opacity(0.7))
                                .clipShape(Circle())
                                .matchedGeometryEffect(id: "actionButton", in: buttonAnimation)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            // Кнопка-трансформер (.idle)
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Микрофон
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
                            } else {
                                // Стрелка
                                Button(action: sendText) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 40, height: 40)
                                        .background(MPColors.accentCoral)
                                        .clipShape(Circle())
                                        .matchedGeometryEffect(id: "actionButton", in: buttonAnimation)
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .padding(6) // Отступы для кнопки
                }
                .background(MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.lg)
                .overlay(
                    RoundedRectangle(cornerRadius: MPCornerRadius.lg)
                        .stroke(MPColors.separator, lineWidth: 1)
                )
                .focused($isFocused)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard text.isEmpty && state == .idle else { continue }
                        withAnimation(.easeInOut(duration: 0.5)) {
                            currentHintIndex = (currentHintIndex + 1) % aiHints.count
                        }
                    }
                }
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.xs)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
        
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
                onError?(String(localized: "error.silenceTimeout"))
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
                onError?(String(localized: "error.rateLimitShort"))
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
            onError?(String(localized: "error.noRecording"))
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
                onError?(String(localized: "error.audioRateLimit"))
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


// MARK: - AIAudioWaveformView (Анимированный эквалайзер с Apple Intelligence Glow)

struct AIAudioWaveformView: View {
    var audioLevel: Float
    
    // Храним 30 последних значений уровня звука для "бегущей волны"
    @State private var history: [CGFloat] = Array(repeating: 0.05, count: 40)
    
    var body: some View {
        let maxWaveHeight: CGFloat = 36
        let barSpacing: CGFloat = 3
        
        // Сама форма волны (маска для градиента)
        HStack(spacing: barSpacing) {
            ForEach(0..<history.count, id: \.self) { i in
                Capsule()
                    // Динамическая высота столбика (минимум 4 пикселя)
                    .frame(height: max(4, history[i] * maxWaveHeight))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxWaveHeight)
        .frame(maxWidth: .infinity, alignment: .center)
        
        // Накладываем Apple Intelligence градиент поверх капсул
        .overlay(
            LinearGradient(
                colors: AIColors.gradientColors,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // И маскируем градиент капсулами, чтобы он рисовался только ВНУТРИ них
        .mask(
            HStack(spacing: barSpacing) {
                ForEach(0..<history.count, id: \.self) { i in
                    Capsule()
                        .frame(height: max(4, history[i] * maxWaveHeight))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: maxWaveHeight)
            .frame(maxWidth: .infinity, alignment: .center)
        )
        
        // Обновляем массив звука 20 раз в секунду
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.7)) {
                history.removeFirst()
                
                // Умножаем уровень громкости, чтобы волна была более "живой" (от 0.05 до 1.0)
                let target = min(1.0, max(0.05, CGFloat(audioLevel) * 1.5))
                history.append(target)
            }
        }
        .onAppear {
            if history.count != 40 {
                history = Array(repeating: 0.05, count: 40)
            }
        }
    }
}
