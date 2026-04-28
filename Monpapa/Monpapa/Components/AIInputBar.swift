// MonPapa iOS — AI Input Bar (Telegram-style ввод транзакций)
// Анимированные состояния: idle → recording → sending → idle
// Интегрирован AudioRecorderService для голосового ввода

import SwiftUI
import Combine
import os

// MARK: - Состояния поля ввода
enum AIInputState {
    case idle       // Обычный ввод (кнопки скрепка + микрофон), либо печать текста
    case recording  // Запись голоса: корзина + волна + отправка
    case sending    // ИИ обрабатывает запрос: свечение AI
}

struct AIInputBar: View {
    @Binding var text: String
    /// Существующие категории для передачи в AI
    var categories: [AICategoryDTO]
    /// Вызывается после успешного AI-парсинга текста
    var onParseResult: (AiParseResult) -> Void
    /// Вызывается после успешного AI-парсинга голоса
    var onVoiceResult: (AiParseResult) -> Void
    /// Вызывается при ошибке
    var onError: ((String) -> Void)?

    private var aiService: AIService { AIService.shared }

    @State private var state: AIInputState = .idle
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6
    @State private var audioRecorder = AudioRecorderService()
    @State private var showMicPermissionAlert = false
    
    // Эффект растворения текста при отправке
    @State private var textOpacity: Double = 1.0

    @FocusState private var isFocused: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentHintIndex = 0
    
    private var aiHints: [String] {
        [
            String(localized: "aiHint.groceries"),
            String(localized: "aiHint.transfer"),
            String(localized: "aiHint.lunch"),
            String(localized: "aiHint.salary"),
            String(localized: "aiHint.fuel")
        ]
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Обычное поле ввода
            if state != .recording {
                mainInputBar
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
            
            // Панель записи голоса — рендерится ТОЛЬКО при записи
            // (lazy: AIAudioWaveformView и его Timer не создаются заранее)
            if state == .recording {
                VStack(spacing: 0) {
                    recordingStatusBar
                    recordingBar
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.xs)
        // Плавная пружинная анимация для элементов интерфейса
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: text.isEmpty)
        
        .alert("Доступ к микрофону", isPresented: $showMicPermissionAlert) {
            Button("Открыть Настройки") { audioRecorder.openSettings() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Для голосового ввода транзакций нужен доступ к микрофону. Включите его в Настройках → MonPapa → Микрофон.")
        }
        .onAppear {
            setupRecorderCallbacks()
        }
    }
    
    // MARK: - Главное поле ввода (Telegram-style)
    private var mainInputBar: some View {
        HStack(alignment: .bottom, spacing: MPSpacing.sm) {
            
            // 🛑 Левая кнопка: Скрепка (или чек)
            Button(action: {
                // TODO: Открытие сканера чеков в будущем
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
            }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 20))
                    .foregroundColor(MPColors.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(MPColors.cardBackground)
                    .clipShape(Circle())
            }
            
            // 🛑 Центральный блок: Текстовое поле + кнопка отправки внутри
            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    
                    // Само поле ввода (от 1 до 3 строк)
                    TextField("", text: $text, axis: .vertical)
                        .font(MPTypography.input)
                        .foregroundColor(MPColors.textPrimary.opacity(textOpacity))
                        .lineLimit(1...3)
                        .padding(.vertical, 10)
                        .padding(.leading, MPSpacing.md)
                        // Если идет набор текста, освобождаем место под кнопку отправки
                        .padding(.trailing, text.isEmpty ? MPSpacing.md : 40)
                        .disabled(state == .sending)
                    
                    // Плейсхолдер
                    if text.isEmpty && state != .sending {
                        Text(aiHints[currentHintIndex])
                            .font(MPTypography.input)
                            .foregroundColor(MPColors.textSecondary.opacity(0.6))
                            .lineLimit(1)
                            .padding(.vertical, 10)
                            .padding(.leading, MPSpacing.md)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .id(currentHintIndex)
                    }
                    
                    // Состояние AI обработки
                    if state == .sending && text.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.8)
                            Text(String(localized: "Работает ИИ..."))
                                .font(MPTypography.input)
                                .foregroundColor(AIColors.gradientColors[1])
                                .lineLimit(1)
                        }
                        .padding(.vertical, 10)
                        .padding(.leading, MPSpacing.md)
                        .transition(.opacity)
                    }
                }
                
                // Кнопка отправки самолетиком (проявляется внутри поля)
                if !text.isEmpty {
                    Button(action: sendText) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .background(MPColors.cardBackground)
            // Радиус 20 для округлого Telegram-вида
            .cornerRadius(20)
            // AI-свечение активируется во время отправки запроса
            .aiBorderGlow(isActive: state == .sending, cornerRadius: 20, lineWidth: 2)
            .focused($isFocused)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard text.isEmpty && state == .idle else { continue }
                    withAnimation(.easeInOut(duration: 0.5)) {
                        currentHintIndex = (currentHintIndex + 1) % aiHints.count
                    }
                }
            }
            
            // 🛑 Правая кнопка: Микрофон (уезжает вправо при вводе текста)
            if text.isEmpty {
                Button(action: startRecording) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundColor(MPColors.accentCoral)
                        .frame(width: 40, height: 40)
                        .background(MPColors.accentCoral.opacity(0.12))
                        .clipShape(Circle())
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
    }
    
    // MARK: - Панель записи голоса
    private var recordingBar: some View {
        HStack(spacing: MPSpacing.md) {
            
            // Кнопка корзины (Отмена)
            Button(action: cancelRecording) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
            }
            
            // Таймер + Звуковая волна
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
            
            // Кнопка отправки (Самолётик)
            Button(action: stopAndSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(MPColors.cardBackground)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(AIColors.gradientColors[1].opacity(0.5), lineWidth: 1)
        )
    }

    private var recordingStatusBar: some View {
        HStack(spacing: MPSpacing.xs) {
            if audioRecorder.recordingDuration > 25 {
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

    // MARK: - Логика действий

    private func setupRecorderCallbacks() {
        audioRecorder.onAutoStop = { fileURL, reason in
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

    private func sendText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isFocused = false
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        // 1. Плавно растворяем текст
        withAnimation(.easeOut(duration: 0.15)) {
            textOpacity = 0.0
        }
        
        // 2. Схлопываем текстовое поле и показываем спиннер AI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                text = "" // Это вернет микрофон справа и схлопнет поле
                textOpacity = 1.0
                state = .sending
            }
            
            // 3. Отправляем запрос
            Task {
                defer { withAnimation { state = .idle } }
                let startedAt = Date()
                MPLog.input.info("⌨️ sendText start | text=\"\(trimmed, privacy: .public)\" categories=\(categories.count)")
                do {
                    let result = try await aiService.parseText(trimmed, categories: categories)
                    MPLog.input.info("⌨️ sendText done | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms | status=\(String(describing: result.status), privacy: .public)")
                    onParseResult(result)
                } catch AIServiceError.rateLimitExceeded {
                    MPLog.input.notice("⌨️ sendText rateLimit | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                    onError?(String(localized: "error.rateLimitShort"))
                } catch {
                    MPLog.input.error("⌨️ sendText error | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms | \(error.localizedDescription, privacy: .public)")
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    private func startRecording() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare() // Подготавливаем Taptic Engine заранее
        impact.impactOccurred()
        
        // Меняем UI МОМЕНТАЛЬНО, не дожидаясь инициализации аудиосессии
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { 
            state = .recording 
        }
        startPulseAnimation()
        
        // await отпускает Main Thread, пока аудиосессия инициализируется.
        // Анимация уже запущена выше и продолжает работать параллельно.
        // Приоритет .userInitiated для быстрого старта аудио.
        Task(priority: .userInitiated) {
            let granted = await audioRecorder.startRecording()
            if !granted {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { 
                    state = .idle 
                }
                stopPulseAnimation()
                showMicPermissionAlert = true
            }
        }
    }

    private func stopAndSend() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
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
                try? FileManager.default.removeItem(at: fileURL)
            }
            let startedAt = Date()
            MPLog.input.info("🎤 sendAudioFile start | file=\(fileURL.lastPathComponent, privacy: .public) categories=\(categories.count)")
            do {
                let result = try await aiService.parseAudio(fileURL: fileURL, categories: categories)
                MPLog.input.info("🎤 sendAudioFile done | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms | status=\(String(describing: result.status), privacy: .public)")
                withAnimation { state = .idle }
                onVoiceResult(result)
            } catch AIServiceError.rateLimitExceeded {
                MPLog.input.notice("🎤 sendAudioFile rateLimit | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                withAnimation { state = .idle }
                onError?(String(localized: "error.audioRateLimit"))
            } catch {
                MPLog.input.error("🎤 sendAudioFile error | \(Int(Date().timeIntervalSince(startedAt) * 1000))ms | \(error.localizedDescription, privacy: .public)")
                withAnimation { state = .idle }
                onError?(error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        // Сначала анимация — моментально обновляем UI
        stopPulseAnimation()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { state = .idle }
        
        // Тяжёлые I/O операции (stop recorder, delete file, deactivate session)
        // выполняются асинхронно, не блокируя Main Thread
        audioRecorder.cancelRecordingFast()
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

// MARK: - AIAudioWaveformView (Анимированный эквалайзер)

struct AIAudioWaveformView: View {
    var audioLevel: Float
    
    @State private var history: [CGFloat] = Array(repeating: 0.05, count: 40)
    
    var body: some View {
        let maxWaveHeight: CGFloat = 36
        let barSpacing: CGFloat = 3
        
        HStack(spacing: barSpacing) {
            ForEach(0..<history.count, id: \.self) { i in
                Capsule()
                    .frame(height: max(4, history[i] * maxWaveHeight))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxWaveHeight)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(
            LinearGradient(
                colors: AIColors.gradientColors,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.7)) {
                history.removeFirst()
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
