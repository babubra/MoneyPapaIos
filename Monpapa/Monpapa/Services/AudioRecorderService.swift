// MonPapa iOS — AudioRecorderService
// Запись голоса через AVAudioRecorder + VAD (Voice Activity Detection)
// Формат: .m4a (AAC, 16kHz, моно) — оптимально для Gemini

import AVFoundation
import Combine
import SwiftUI

// MARK: - Состояния записи

enum RecordingState: Equatable {
    case idle
    case recording
    case stopped(URL)  // файл готов к отправке
}

// MARK: - Callbacks

enum RecordingStopReason {
    case manual            // Пользователь нажал «Отправить»
    case silenceTimeout    // Тишина > 5 сек, речь не обнаружена
    case pauseAfterSpeech  // Пауза > 3 сек после речи
    case maxDuration       // 30 сек активной речи
    case error(String)     // Ошибка записи
}

// MARK: - AudioRecorderService

@Observable
final class AudioRecorderService: NSObject {

    // MARK: - Public state

    private(set) var state: RecordingState = .idle
    private(set) var isRecording = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var audioLevel: Float = 0  // 0...1, для визуализации пульса

    // MARK: - Callbacks

    /// Вызывается при автостопе с готовым файлом
    var onAutoStop: ((URL, RecordingStopReason) -> Void)?
    /// Вызывается при ошибке/тишине (без файла)
    var onError: ((RecordingStopReason) -> Void)?

    // MARK: - Private

    private var recorder: AVAudioRecorder?
    private var meteringTimer: AnyCancellable?
    private var currentFileURL: URL?

    // VAD параметры
    private var speechDetected = false
    private var silenceDuration: TimeInterval = 0
    private var activeSpeechDuration: TimeInterval = 0
    private let meteringInterval: TimeInterval = 0.1

    // VAD пороги (в децибелах, AVAudioRecorder возвращает от -160 до 0)
    private let speechThreshold: Float = -30   // выше = речь
    private let silenceThreshold: Float = -40   // ниже = тишина
    private let maxSilenceBeforeSpeech: TimeInterval = 5.0
    private let maxSilenceAfterSpeech: TimeInterval = 3.0
    private let maxActiveSpeech: TimeInterval = 30.0

    // MARK: - Permissions

    /// Проверяет и запрашивает разрешение на микрофон.
    /// Возвращает `true` если разрешение получено.
    func requestPermission() async -> Bool {
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Открывает настройки приложения (для включения микрофона)
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Recording

    /// Начинает запись. Возвращает `false` если нет разрешения.
    @discardableResult
    func startRecording() async -> Bool {
        guard await requestPermission() else { return false }

        // Настраиваем аудио-сессию
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            onError?(.error(String(localized: "error.audioSetup \(error.localizedDescription)")))
            return false
        }

        // Путь к файлу в temp
        let fileName = "monpapa_voice_\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        currentFileURL = fileURL

        // Настройки записи: AAC, 16kHz, моно
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.delegate = self
            recorder?.record()
        } catch {
            onError?(.error(String(localized: "error.audioStart \(error.localizedDescription)")))
            return false
        }

        // Сбрасываем VAD-состояние
        speechDetected = false
        silenceDuration = 0
        activeSpeechDuration = 0
        recordingDuration = 0
        audioLevel = 0

        isRecording = true
        state = .recording

        // Запускаем таймер мониторинга (VAD)
        startMetering()

        return true
    }

    /// Останавливает запись и возвращает файл.
    func stopRecording() -> URL? {
        stopMetering()
        recorder?.stop()
        isRecording = false

        deactivateAudioSession()

        if let url = currentFileURL, FileManager.default.fileExists(atPath: url.path) {
            state = .stopped(url)
            return url
        }
        state = .idle
        return nil
    }

    /// Отменяет запись и удаляет файл.
    func cancelRecording() {
        stopMetering()
        recorder?.stop()
        recorder?.deleteRecording()
        isRecording = false
        currentFileURL = nil
        state = .idle

        deactivateAudioSession()
    }

    /// Сбрасывает состояние после отправки.
    func reset() {
        state = .idle
        currentFileURL = nil
        recordingDuration = 0
        audioLevel = 0
    }

    // MARK: - VAD Metering

    private func startMetering() {
        meteringTimer = Timer.publish(every: meteringInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.processMeteringTick()
            }
    }

    private func stopMetering() {
        meteringTimer?.cancel()
        meteringTimer = nil
    }

    private func processMeteringTick() {
        guard let recorder, recorder.isRecording else { return }

        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // -160...0 dB

        // Обновляем визуализацию (нормализуем в 0...1)
        let normalizedLevel = max(0, min(1, (power + 50) / 50))
        audioLevel = normalizedLevel

        // Обновляем длительность
        recordingDuration = recorder.currentTime

        // --- VAD логика ---

        if power > speechThreshold {
            // Обнаружена речь
            speechDetected = true
            silenceDuration = 0
            activeSpeechDuration += meteringInterval

            // Лимит 30 сек активной речи
            if activeSpeechDuration >= maxActiveSpeech {
                autoStop(reason: .maxDuration)
                return
            }
        } else if power < silenceThreshold {
            // Тишина
            silenceDuration += meteringInterval

            if !speechDetected && silenceDuration >= maxSilenceBeforeSpeech {
                // 5 сек тишины, речь не начиналась → "Я вас не слышу"
                cancelRecording()
                onError?(.silenceTimeout)
                return
            }

            if speechDetected && silenceDuration >= maxSilenceAfterSpeech {
                // 3 сек тишины после речи → автоотправка
                autoStop(reason: .pauseAfterSpeech)
                return
            }
        }
        // Промежуточная зона (-40...-30) — не меняем состояние
    }

    private func autoStop(reason: RecordingStopReason) {
        guard let url = stopRecording() else {
            onError?(.error(String(localized: "error.recordingFileNotFound")))
            return
        }
        onAutoStop?(url, reason)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Форматирование

    /// Длительность записи как "0:05", "0:30"
    var formattedDuration: String {
        let seconds = Int(recordingDuration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorderService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            isRecording = false
            state = .idle
            onError?(.error(String(localized: "error.recordingFailed")))
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        isRecording = false
        state = .idle
        onError?(.error(String(localized: "error.encodingFailed \(error?.localizedDescription ?? "unknown")")))
    }
}
