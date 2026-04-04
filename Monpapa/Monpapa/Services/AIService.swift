// MonPapa iOS — AI Service
// HTTP-клиент для backend MonPapa API
// Эндпоинты: POST /api/v1/auth/device, /api/v1/ai/parse, /api/v1/ai/parse-audio

import Foundation

// MARK: - Конфигурация

private enum APIConfig {
    /// Базовый URL бэкенда.
    /// В разработке — localhost. В продакшне — замени на реальный домен.
    #if DEBUG
    static let baseURL = "http://localhost:8001"
    #else
    static let baseURL = "https://api.monpapa.app"   // TODO: заменить на реальный
    #endif

    static let apiVersion = "/api/v1"
    static let tokenKey   = "monpapa_auth_token"
    static let deviceIdKey = "monpapa_device_id"
}

// MARK: - Ошибки сервиса

enum AIServiceError: LocalizedError {
    case noToken
    case networkError(Error)
    case serverError(Int, String)
    case rateLimitExceeded
    case decodingError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Устройство не авторизовано — попробуйте перезапустить приложение"
        case .networkError(let error):
            return "Ошибка сети: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Ошибка сервера (\(code)): \(message)"
        case .rateLimitExceeded:
            return "Достигнут дневной лимит AI-запросов. Попробуйте завтра."
        case .decodingError(let error):
            return "Не удалось разобрать ответ: \(error.localizedDescription)"
        case .invalidResponse:
            return "Неожиданный ответ сервера"
        }
    }
}

// MARK: - Категория/субъект для передачи в запросе

struct AICategoryDTO: Codable {
    let id: String
    let name: String
    let type: String    // "income" | "expense"
    let aiHint: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case aiHint = "ai_hint"
    }
}

struct AICounterpartDTO: Codable {
    let id: String
    let name: String
}

// MARK: - AI Service

@MainActor
final class AIService {

    static let shared = AIService()
    private init() {}

    // MARK: - Хранение токена

    private var authToken: String? {
        get { UserDefaults.standard.string(forKey: APIConfig.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: APIConfig.tokenKey) }
    }

    private var deviceId: String {
        if let stored = UserDefaults.standard.string(forKey: APIConfig.deviceIdKey) {
            return stored
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: APIConfig.deviceIdKey)
        return new
    }

    // MARK: - Авторизация устройства

    /// Регистрирует устройство на сервере и сохраняет Bearer-токен.
    /// Вызывать при запуске приложения (MonpapaApp.swift → .task {}).
    func authenticateIfNeeded() async {
        guard authToken == nil else { return }
        do {
            try await authenticate()
        } catch {
            print("[AIService] ⚠️ Авторизация не удалась: \(error.localizedDescription)")
        }
    }

    func authenticate() async throws {
        let url = URL(string: "\(APIConfig.baseURL)\(APIConfig.apiVersion)/auth/device")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["device_id": deviceId])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
        authToken = decoded.accessToken
        print("[AIService] ✅ Устройство авторизовано, токен сохранён")
    }

    // MARK: - AI Текстовый парсинг

    func parseText(
        _ text: String,
        categories: [AICategoryDTO] = [],
        counterparts: [AICounterpartDTO] = []
    ) async throws -> AiParseResult {
        guard let token = authToken else {
            // Пробуем переавторизоваться один раз
            try await authenticate()
            guard authToken != nil else { throw AIServiceError.noToken }
            return try await parseText(text, categories: categories, counterparts: counterparts)
        }

        let url = URL(string: "\(APIConfig.baseURL)\(APIConfig.apiVersion)/ai/parse")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = ParseTextRequest(
            text: text,
            categories: categories,
            counterparts: counterparts,
            locale: Locale.current.language.languageCode?.identifier ?? "ru"
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Токен мог протухнуть → переавторизуемся и повторяем
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            authToken = nil
            try await authenticate()
            return try await parseText(text, categories: categories, counterparts: counterparts)
        }

        try validateResponse(response, data: data)
        return try decode(AiParseResult.self, from: data)
    }

    // MARK: - AI Голосовой парсинг

    func parseAudio(
        fileURL: URL,
        categories: [AICategoryDTO] = [],
        counterparts: [AICounterpartDTO] = []
    ) async throws -> AiParseResult {
        guard let token = authToken else {
            try await authenticate()
            guard authToken != nil else { throw AIServiceError.noToken }
            return try await parseAudio(fileURL: fileURL, categories: categories, counterparts: counterparts)
        }

        let url = URL(string: "\(APIConfig.baseURL)\(APIConfig.apiVersion)/ai/parse-audio")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let audioData = try Data(contentsOf: fileURL)
        let categoriesJSON = (try? JSONEncoder().encode(categories)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let counterpartsJSON = (try? JSONEncoder().encode(counterparts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        request.httpBody = buildMultipart(
            boundary: boundary,
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            categories: categoriesJSON,
            counterparts: counterpartsJSON,
            locale: Locale.current.language.languageCode?.identifier ?? "ru"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
        return try decode(AiParseResult.self, from: data)
    }

    // MARK: - Приватные хелперы

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw AIServiceError.noToken
        case 429:       throw AIServiceError.rateLimitExceeded
        default:
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail ?? "Unknown error"
            throw AIServiceError.serverError(http.statusCode, message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIServiceError.decodingError(error)
        }
    }

    private func buildMultipart(
        boundary: String,
        audioData: Data,
        fileName: String,
        categories: String,
        counterparts: String,
        locale: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ string: String) { body.append(Data(string.utf8)) }

        // Аудиофайл
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\(crlf)")
        append("Content-Type: audio/m4a\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        // Категории
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"categories\"\(crlf)\(crlf)")
        append(categories + crlf)

        // Субъекты
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"counterparts\"\(crlf)\(crlf)")
        append(counterparts + crlf)

        // Локаль
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"locale\"\(crlf)\(crlf)")
        append(locale + crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }
}

// MARK: - Вспомогательные Codable-структуры

private struct AuthResponse: Codable {
    let accessToken: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType   = "token_type"
    }
}

private struct ParseTextRequest: Codable {
    let text: String
    let categories: [AICategoryDTO]
    let counterparts: [AICounterpartDTO]
    let locale: String
}

private struct ErrorResponse: Codable {
    let detail: String
}
