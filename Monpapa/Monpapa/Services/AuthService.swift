// MonPapa iOS — Auth Service
// Авторизация пользователя:
//   • Sign in with Apple (primary) — через AuthenticationServices + backend /auth/apple
//   • Magic Link (fallback) — email → PIN → /auth/verify-pin
//
// JWT хранится в Keychain (KeychainService.Keys.userToken). После Auth Model C
// этот же токен используется для AI и Sync — отдельный device-токен из старой
// модели больше не выдаётся (см. /auth/device → 404).

import Foundation
import Combine
import AuthenticationServices
import UIKit

// MARK: - Ошибки авторизации

enum AuthError: LocalizedError {
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse
    case invalidCredentials
    case notAuthenticated
    case appleSignInUnavailable      // нет entitlement, нет Apple ID, runtime error
    case appleSignInCancelled        // пользователь отменил popup

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return String(localized: "auth.error.network \(error.localizedDescription)")
        case .serverError(let code, let message):
            return String(localized: "auth.error.server \(code) \(message)")
        case .invalidResponse:
            return String(localized: "auth.error.invalidResponse")
        case .invalidCredentials:
            return String(localized: "auth.error.invalidCredentials")
        case .notAuthenticated:
            return String(localized: "auth.error.notAuthenticated")
        case .appleSignInUnavailable:
            return String(localized: "auth.signin.apple.unavailable")
        case .appleSignInCancelled:
            return String(localized: "auth.signin.apple.cancelled")
        }
    }
}

// MARK: - Auth Service

@MainActor
final class AuthService: NSObject, ObservableObject {

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

    /// device_id — общий между Auth/AI/Sync, лежит в Keychain.
    /// После Auth Model C device_id передаётся при логине только для метаданных
    /// на сервере (last_seen_at), но не для авторизации.
    private var deviceId: String {
        if let stored = KeychainService.load(key: KeychainService.Keys.deviceId) {
            return stored
        }
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
        APIConfig.baseURL
    }

    private var apiBase: String { "\(baseURL)/api/v1/auth" }

    // MARK: - Apple Sign-In state

    /// Continuation для async-обёртки над delegate-based ASAuthorizationController.
    /// nil означает "нет активного запроса". Защищаем от двойного resume через nilling.
    private var appleSignInContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Инициализация

    private override init() {
        super.init()
        // Миграция: перенос данных из UserDefaults → Keychain (однократно)
        migrateFromUserDefaults()

        // Восстанавливаем состояние из Keychain
        self.isAuthenticated = KeychainService.load(key: KeychainService.Keys.userToken) != nil
        self.userEmail = KeychainService.load(key: KeychainService.Keys.userEmail)
    }

    // MARK: - Sign in with Apple

    /// Запускает Apple Sign-In flow и обменивает identity_token на user-JWT.
    ///
    /// Без entitlement `com.apple.developer.applesignin` (Personal Team Xcode) Apple
    /// возвращает delegate-error → бросаем `.appleSignInUnavailable`. UI показывает
    /// friendly fallback "Войдите по Email".
    ///
    /// TODO для production: добавить `Monpapa.entitlements` с ключом
    /// `com.apple.developer.applesignin` и зарегистрировать Bundle ID
    /// `fatau.Monpapa` на developer.apple.com.
    func signInWithApple() async throws {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.email, .fullName]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.appleSignInContinuation = continuation
            controller.performRequests()
        }
    }

    /// Выполняется после успешного получения identity_token от Apple.
    /// Отправляет токен на бэкенд, получает JWT, сохраняет в Keychain.
    private func exchangeAppleToken(identityToken: String, fullName: String?, email: String?) async throws {
        let url = URL(string: "\(apiBase)/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "identity_token": identityToken,
            "device_id": deviceId,
        ]
        if let fullName, !fullName.isEmpty {
            body["full_name"] = fullName
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[AuthService] 🍎 signInWithApple → POST /auth/apple deviceId=\(deviceId)")

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        userToken = tokenResponse.accessToken
        if let email, !email.isEmpty {
            let normalized = email.lowercased()
            userEmail = normalized
            KeychainService.save(key: KeychainService.Keys.userEmail, value: normalized)
        }

        print("[AuthService] ✅ Apple Sign-In success isAuthenticated=\(isAuthenticated)")
    }

    // MARK: - Magic Link (fallback)

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

        print("[AuthService] 📧 requestMagicLink: URL=\(url.absoluteString), email=\(email)")

        let (data, response) = try await performRequest(request)

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[AuthService] 📧 requestMagicLink response: HTTP \(httpStatus)")

        try validateResponse(response, data: data)

        // В DEV_MODE бэкенд может вернуть токен сразу
        if let devResponse = try? JSONDecoder().decode(DevModeResponse.self, from: data),
           let token = devResponse.token {
            print("[AuthService] 🛠️ DEV_MODE: получен токен напрямую")
            userToken = token
            let normalizedEmail = email.lowercased()
            userEmail = normalizedEmail
            KeychainService.save(key: KeychainService.Keys.userEmail, value: normalizedEmail)
            if let userId = devResponse.userId {
                KeychainService.save(key: KeychainService.Keys.userId, value: String(userId))
            }
            print("[AuthService] ✅ DEV_MODE: пользователь авторизован напрямую, isAuthenticated=\(isAuthenticated)")
            return
        }

        print("[AuthService] 📧 PIN-код отправлен на \(email)")
    }

    /// Шаг 2: Верифицировать PIN-код, полученный на email.
    /// При успехе — сохраняет user-JWT и привязывает device к user.
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

        print("[AuthService] 🔑 verifyPin: URL=\(url.absoluteString), email=\(email), deviceId=\(deviceId)")

        let (data, response) = try await performRequest(request)

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[AuthService] 🔑 verifyPin response: HTTP \(httpStatus)")

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

        print("[AuthService] ✅ Пользователь авторизован: \(email), isAuthenticated=\(isAuthenticated)")
    }

    /// Выход из аккаунта — очищает все данные из Keychain.
    func logout() {
        userToken = nil
        userEmail = nil
        KeychainService.delete(key: KeychainService.Keys.userToken)
        KeychainService.delete(key: KeychainService.Keys.userEmail)
        KeychainService.delete(key: KeychainService.Keys.userId)
        // Старый device-токен тоже чистим — после Auth Model C он бесполезен.
        KeychainService.delete(key: KeychainService.Keys.deviceToken)
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

    /// JWT-токен для использования в других сервисах (AIService, SyncService).
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
        // Retry-логика: iOS переиспользует keep-alive TCP-соединения.
        // Если сервер закрыл idle-соединение (пока пользователь читал email),
        // iOS получает -1005 "Connection reset by peer" при повторном использовании.
        // Retry с небольшой задержкой открывает новое соединение.
        let maxRetries = 2
        for attempt in 0...maxRetries {
            do {
                return try await URLSession.shared.data(for: request)
            } catch let error as NSError where error.code == NSURLErrorNetworkConnectionLost && attempt < maxRetries {
                // -1005: соединение сброшено — ждём и пробуем снова
                print("[AuthService] ⚠️ Connection lost (attempt \(attempt + 1)/\(maxRetries + 1)), retrying...")
                try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 300_000_000) // 300ms, 600ms
                continue
            } catch {
                throw AuthError.networkError(error)
            }
        }
        // unreachable, но компилятор требует
        throw AuthError.networkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
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

// MARK: - ASAuthorizationControllerDelegate / PresentationContextProviding

extension AuthService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        // Обрабатываем результат на main actor (UI + Keychain).
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                self.finishAppleSignIn(.failure(AuthError.invalidResponse))
                return
            }

            let givenName = credential.fullName?.givenName ?? ""
            let familyName = credential.fullName?.familyName ?? ""
            let combinedName = [givenName, familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let fullName = combinedName.isEmpty ? nil : combinedName
            let email = credential.email

            do {
                try await self.exchangeAppleToken(
                    identityToken: identityToken,
                    fullName: fullName,
                    email: email
                )
                self.finishAppleSignIn(.success(()))
            } catch {
                self.finishAppleSignIn(.failure(error))
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let mapped: AuthError
            if let asError = error as? ASAuthorizationError {
                switch asError.code {
                case .canceled:
                    mapped = .appleSignInCancelled
                default:
                    // Любая другая ошибка от Apple (включая будущие enum cases в новых iOS):
                    // нет entitlement, неудачный handshake, etc. — для UI это «недоступно».
                    mapped = .appleSignInUnavailable
                }
            } else {
                mapped = .networkError(error)
            }
            print("[AuthService] ❌ Apple Sign-In error: \(error) → \(mapped)")
            self.finishAppleSignIn(.failure(mapped))
        }
    }

    @MainActor
    private func finishAppleSignIn(_ result: Result<Void, Error>) {
        guard let continuation = appleSignInContinuation else { return }
        appleSignInContinuation = nil
        switch result {
        case .success: continuation.resume(returning: ())
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Apple вызывает делегат на главном потоке, поэтому assumeIsolated безопасен.
        // Без этой обёртки Swift 6 strict-concurrency жалуется на доступ к
        // main-actor-изолированному UIApplication.shared из nonisolated-метода.
        MainActor.assumeIsolated {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return window
            }
            // Fallback — Apple покажет ошибку, мы уйдём в .appleSignInUnavailable.
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                return UIWindow(windowScene: scene)
            }
            return UIWindow()
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
