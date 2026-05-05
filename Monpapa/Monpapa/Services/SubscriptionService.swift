// MonPapa iOS — Subscription Service
//
// Состояние подписки + AI trial counter, синхронизированные с backend.
// Endpoint'ы: GET /api/v1/subscription/status, POST /api/v1/subscription/verify
//
// StoreKit 2 пока не интегрирован (нет Apple Developer Program). PaywallView
// дёргает purchaseStub() который шлёт DEV_STUB-receipt → backend ставит
// status='active'. После получения dev-аккаунта заменить на реальный
// StoreKit-purchase + Transaction.verify().

import Foundation
import Combine

// MARK: - Ошибки

enum SubscriptionError: LocalizedError {
    case notAuthenticated
    case networkError(Error)
    case serverError(Int, String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "error.notAuthenticated")
        case .networkError(let e):
            return e.localizedDescription
        case .serverError(let code, let msg):
            return "HTTP \(code): \(msg)"
        case .decodingError(let e):
            return e.localizedDescription
        }
    }
}

// MARK: - Subscription Service

@MainActor
final class SubscriptionService: ObservableObject {

    static let shared = SubscriptionService()

    // MARK: - Published state

    /// free | active | expired | cancelled
    @Published private(set) var status: String = "free"
    @Published private(set) var aiTrialUsed: Int = 0
    @Published private(set) var aiTrialLimit: Int = 50
    @Published private(set) var expiresAt: Date?
    @Published private(set) var productId: String?

    /// True пока идёт refreshStatus / purchaseStub.
    @Published private(set) var isBusy: Bool = false

    // MARK: - Computed

    /// Сколько AI-запросов осталось у free-юзера. Для Premium всегда 0 (но hasAccess=true).
    var trialRemaining: Int {
        max(0, aiTrialLimit - aiTrialUsed)
    }

    /// Есть ли у юзера право на AI: либо активная подписка, либо ещё trial.
    var hasAIAccess: Bool {
        isPremium || trialRemaining > 0
    }

    /// Активна ли подписка (с проверкой expiry).
    var isPremium: Bool {
        guard status == "active" else { return false }
        if let expiresAt {
            return expiresAt > Date()
        }
        return true  // expires_at == NULL = бессрочный (обычно админ/тест-аккаунт)
    }

    /// Стоит ли показывать AI-counter в UI: только для free, не для премиум.
    var shouldShowTrialCounter: Bool {
        !isPremium
    }

    // MARK: - Init

    private init() {}

    // MARK: - Конфигурация

    private var baseURL: String { APIConfig.baseURL }
    private var apiBase: String { "\(baseURL)/api/v1/subscription" }

    private var token: String? { AuthService.shared.token }

    // MARK: - Refresh status

    /// Подтягивает актуальный статус подписки и AI trial counter из backend.
    func refreshStatus() async {
        guard let token else {
            // Юзер не авторизован — сбрасываем state до дефолтов.
            status = "free"
            aiTrialUsed = 0
            expiresAt = nil
            productId = nil
            return
        }

        let url = URL(string: "\(apiBase)/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        isBusy = true
        defer { isBusy = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validateResponse(response, data: data)
            let dto = try JSONDecoder.subscriptionDecoder.decode(SubscriptionStatusDTO.self, from: data)
            apply(dto: dto)
            print("[SubscriptionService] ↻ status=\(status) trial=\(aiTrialUsed)/\(aiTrialLimit) expires=\(expiresAt as Any)")
        } catch {
            print("[SubscriptionService] ⚠️ refreshStatus failed: \(error)")
        }
    }

    /// Локальный счётчик: после удачного AI-запроса iOS-сторона может вызвать
    /// noteTrialConsumedLocally() чтобы UI обновился без round-trip к серверу.
    /// На следующем refreshStatus() значение всё равно перезатрётся серверным.
    func noteTrialConsumedLocally() {
        guard !isPremium else { return }
        aiTrialUsed = min(aiTrialLimit, aiTrialUsed + 1)
    }

    // MARK: - Purchase (DEV-stub)

    /// DEV-заглушка вместо StoreKit 2. Дёргает /verify с фейковым receipt'ом —
    /// backend ставит юзеру subscription_status='active' на 30 дней.
    ///
    /// TODO для production:
    ///   1. let products = try await Product.products(for: ["monpapa.premium.monthly"])
    ///   2. let result = try await products.first?.purchase()
    ///   3. case .success(let verification) = result; let transaction = try checkVerified(verification)
    ///   4. POST /verify { receipt_data: jws_payload, product_id, original_transaction_id }
    func purchaseStub() async throws {
        guard let token else { throw SubscriptionError.notAuthenticated }

        let url = URL(string: "\(apiBase)/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "receipt_data": "DEV_STUB",
            "product_id": "monpapa.premium.monthly",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        isBusy = true
        defer { isBusy = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validateResponse(response, data: data)
            let dto = try JSONDecoder.subscriptionDecoder.decode(VerifyReceiptDTO.self, from: data)
            self.status = dto.subscriptionStatus
            self.expiresAt = dto.subscriptionExpiresAt
            self.productId = dto.subscriptionProductId
            print("[SubscriptionService] 💳 purchaseStub success: status=\(status) expires=\(expiresAt as Any) is_stub=\(dto.isStub)")
        } catch let error as SubscriptionError {
            throw error
        } catch let urlError as URLError {
            throw SubscriptionError.networkError(urlError)
        } catch let decErr as DecodingError {
            throw SubscriptionError.decodingError(decErr)
        }
    }

    // MARK: - Helpers

    private func apply(dto: SubscriptionStatusDTO) {
        self.status = dto.subscriptionStatus
        self.expiresAt = dto.subscriptionExpiresAt
        self.productId = dto.subscriptionProductId
        self.aiTrialUsed = dto.aiTrialUsed
        self.aiTrialLimit = dto.aiTrialLimit
    }

    private static func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionError.serverError(-1, "Invalid response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw SubscriptionError.notAuthenticated
        default:
            let detail = (try? JSONDecoder().decode(ErrorDetailDTO.self, from: data))?.detail ?? "Unknown error"
            throw SubscriptionError.serverError(http.statusCode, detail)
        }
    }
}

// MARK: - DTOs

private struct SubscriptionStatusDTO: Decodable {
    let subscriptionStatus: String
    let subscriptionExpiresAt: Date?
    let subscriptionProductId: String?
    let aiTrialUsed: Int
    let aiTrialLimit: Int

    enum CodingKeys: String, CodingKey {
        case subscriptionStatus      = "subscription_status"
        case subscriptionExpiresAt   = "subscription_expires_at"
        case subscriptionProductId   = "subscription_product_id"
        case aiTrialUsed             = "ai_trial_used"
        case aiTrialLimit            = "ai_trial_limit"
    }
}

private struct VerifyReceiptDTO: Decodable {
    let subscriptionStatus: String
    let subscriptionExpiresAt: Date?
    let subscriptionProductId: String?
    let isStub: Bool

    enum CodingKeys: String, CodingKey {
        case subscriptionStatus    = "subscription_status"
        case subscriptionExpiresAt = "subscription_expires_at"
        case subscriptionProductId = "subscription_product_id"
        case isStub                = "is_stub"
    }
}

private struct ErrorDetailDTO: Decodable {
    let detail: String
}

// MARK: - JSONDecoder для backend timestamps (ISO-8601 с микросекундами)

private extension JSONDecoder {
    /// Декодер с поддержкой ISO8601 (включая дробные секунды и UTC-Z, как pydantic выдаёт).
    static let subscriptionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let d = formatter.date(from: s) ?? formatterNoFrac.date(from: s) {
                return d
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Cannot parse date: \(s)")
        }
        return decoder
    }()
}
