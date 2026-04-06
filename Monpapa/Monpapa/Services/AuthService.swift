// MonPapa iOS — Auth Service
// Авторизация пользователя: Magic Link (email → PIN → JWT)
// Для синхронизации данных между устройствами.
//
// Не путать с device-auth в AIService — тот для анонимного AI-доступа.
// AuthService = авторизация пользователя = доступ к синхронизации.
//
// Хранение: все секреты (token, email, userId) — в Keychain.

import Foundation
import Combine

// MARK: - Ошибки авторизации

enum AuthError: LocalizedError {
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse
    case invalidCredentials
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Ошибка сети: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Ошибка сервера (\(code)): \(message)"
        case .invalidResponse:
            return "Неожиданный ответ сервера"
        case .invalidCredentials:
            return "Неверный или просроченный код"
        case .notAuthenticated:
            return "Пользователь не авторизован"
        }
    }
}

// MARK: - Auth Service

@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    // MARK: - Устаревшие ключи UserDefaults (для миграции)

    private enum LegacyKeys {
        static let userToken = "monpapa_user_token"
        static let userEmail = "monpapa_user_email"
        static let userId    = "monpapa_user_id"
    }

    // MARK: - Published-свойства (для UI)

    /// Авторизован ли пользователь (есть ли JWT-токен)
    @Published private(set) var isAuthenticated: Bool = false

    /// Email авторизованного пользователя
    @Published private(set) var userEmail: String? = nil

    // MARK: - Приватное хранение (Keychain)

    /// JWT-токен пользователя (хранится в Keychain)
    private var userToken: String? {
        get { KeychainService.load(key: KeychainService.Keys.userToken) }
        set {
            if let value = newValue {
                KeychainService.save(key: KeychainService.Keys.userToken, value: value)
            } else {
                KeychainService.delete(key: KeychainService.Keys.userToken)
            }
            isAuthenticated = newValue != nil
        }
    }

    /// device_id — берём общий из Keychain (общий с AIService)
    private var deviceId: String {
        if let stored = KeychainService.load(key: KeychainService.Keys.deviceId) {
            return stored
        }
        // Если AIService уже создал device_id в UserDefaults — мигрируем его
        if let legacy = UserDefaults.standard.string(forKey: "monpapa_device_id") {
            KeychainService.save(key: KeychainService.Keys.deviceId, value: legacy)
            return legacy
        }
        let new = UUID().uuidString
        KeychainService.save(key: KeychainService.Keys.deviceId, value: new)
        return new
    }

    // MARK: - Конфигурация

    private var baseURL: String {
        #if DEBUG
        return "http://localhost:8001"
        #else
        return "https://api.monpapa.app"
        #endif
    }

    private var apiBase: String { "\(baseURL)/api/v1/auth" }

    // MARK: - Инициализация

    private init() {
        // Миграция: перенос данных из UserDefaults → Keychain (однократно)
        migrateFromUserDefaults()

        // Восстанавливаем состояние из Keychain
        self.isAuthenticated = KeychainService.load(key: KeychainService.Keys.userToken) != nil
        self.userEmail = KeychainService.load(key: KeychainService.Keys.userEmail)
    }

    // MARK: - Публичный API

    /// Шаг 1: Отправить Magic Link на email.
    /// Бэкенд отправит письмо с 6-значным PIN-кодом.
    /// В DEV_MODE — сразу вернёт токен (без письма).
    func requestMagicLink(email: String) async throws {
        let url = URL(string: "\(apiBase)/request-link")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email.lowercased().trimmingCharacters(in: .whitespaces)]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        // В DEV_MODE бэкенд может вернуть токен сразу
        if let devResponse = try? JSONDecoder().decode(DevModeResponse.self, from: data),
           let token = devResponse.token {
            userToken = token
            let normalizedEmail = email.lowercased()
            userEmail = normalizedEmail
            KeychainService.save(key: KeychainService.Keys.userEmail, value: normalizedEmail)
            if let userId = devResponse.userId {
                KeychainService.save(key: KeychainService.Keys.userId, value: String(userId))
            }
            print("[AuthService] ✅ DEV_MODE: пользователь авторизован напрямую")
            return
        }

        print("[AuthService] 📧 PIN-код отправлен на \(email)")
    }

    /// Шаг 2: Верифицировать PIN-код, полученный на email.
    /// При успехе — сохраняет JWT-токен и привязывает device к user.
    func verifyPin(email: String, code: String) async throws {
        let url = URL(string: "\(apiBase)/verify-pin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PinVerifyBody(
            email: email.lowercased().trimmingCharacters(in: .whitespaces),
            code: code.trimmingCharacters(in: .whitespaces),
            deviceId: deviceId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(request)

        // 401 = неверный PIN
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw AuthError.invalidCredentials
        }

        try validateResponse(response, data: data)

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        userToken = tokenResponse.accessToken
        let normalizedEmail = email.lowercased()
        userEmail = normalizedEmail
        KeychainService.save(key: KeychainService.Keys.userEmail, value: normalizedEmail)

        print("[AuthService] ✅ Пользователь авторизован: \(email)")
    }

    /// Выход из аккаунта — очищает все данные из Keychain.
    func logout() {
        userToken = nil
        userEmail = nil
        KeychainService.delete(key: KeychainService.Keys.userToken)
        KeychainService.delete(key: KeychainService.Keys.userEmail)
        KeychainService.delete(key: KeychainService.Keys.userId)
        print("[AuthService] 🚪 Пользователь вышел")
    }
    
    /// Полное удаление аккаунта на сервере + локальный logout.
    /// Требование Apple App Store Review Guidelines 5.1.1(v).
    func deleteAccount() async throws {
        guard let token = userToken else {
            throw AuthError.notAuthenticated
        }
        
        let url = URL(string: "\(apiBase)/account")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        
        print("[AuthService] 🗑️ Аккаунт удалён на сервере")
        
        // Локальный logout
        logout()
    }

    /// JWT-токен для использования в других сервисах (SyncService).
    /// Возвращает nil если пользователь не авторизован.
    var token: String? { userToken }

    // MARK: - Миграция UserDefaults → Keychain

    /// Однократная миграция: если данные есть в UserDefaults — переносим в Keychain
    /// и удаляем из UserDefaults (секреты не должны храниться в открытом виде).
    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard

        if let token = defaults.string(forKey: LegacyKeys.userToken) {
            KeychainService.save(key: KeychainService.Keys.userToken, value: token)
            defaults.removeObject(forKey: LegacyKeys.userToken)
            print("[AuthService] 🔄 Мигрирован userToken → Keychain")
        }

        if let email = defaults.string(forKey: LegacyKeys.userEmail) {
            KeychainService.save(key: KeychainService.Keys.userEmail, value: email)
            defaults.removeObject(forKey: LegacyKeys.userEmail)
            print("[AuthService] 🔄 Мигрирован userEmail → Keychain")
        }

        if let userId = defaults.string(forKey: LegacyKeys.userId) {
            KeychainService.save(key: KeychainService.Keys.userId, value: userId)
            defaults.removeObject(forKey: LegacyKeys.userId)
            print("[AuthService] 🔄 Мигрирован userId → Keychain")
        }
    }

    // MARK: - Приватные хелперы

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.networkError(error)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw AuthError.invalidCredentials
        default:
            let message = (try? JSONDecoder().decode(ErrorDetail.self, from: data))?.detail ?? "Unknown error"
            throw AuthError.serverError(http.statusCode, message)
        }
    }
}

// MARK: - Codable-структуры

private struct PinVerifyBody: Codable {
    let email: String
    let code: String
    let deviceId: String

    enum CodingKeys: String, CodingKey {
        case email, code
        case deviceId = "device_id"
    }
}

private struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType   = "token_type"
    }
}

private struct DevModeResponse: Codable {
    let message: String?
    let token: String?
    let userId: Int?

    enum CodingKeys: String, CodingKey {
        case message, token
        case userId = "user_id"
    }
}

private struct ErrorDetail: Codable {
    let detail: String
}
