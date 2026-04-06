// MonPapa iOS — Keychain Service
// Безопасное хранение токенов и device_id в iOS Keychain.
//
// Keychain сохраняет данные в зашифрованном виде,
// данные сохраняются даже после удаления приложения (до сброса устройства).
// UserDefaults — открытый plist-файл, не подходит для секретов.

import Foundation
import Security

enum KeychainService {

    /// Идентификатор сервиса для всех записей MonPapa
    private static let service = "app.monpapa.keychain"

    // MARK: - Публичный API

    /// Сохранить строку в Keychain.
    /// Если ключ уже существует — перезаписывает.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Удаляем старое значение, если есть
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecValueData as String:    data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] ⚠️ save(\(key)) failed: \(status)")
        }
        return status == errSecSuccess
    }

    /// Прочитать строку из Keychain. Nil — если ключ не найден.
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]

        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)

        guard status == errSecSuccess, let data = ref as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Удалить значение из Keychain.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Проверить наличие ключа (без чтения значения).
    static func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecReturnData as String:   false
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Ключи MonPapa

extension KeychainService {

    /// Предопределённые ключи для всех сервисов приложения
    enum Keys {
        /// JWT-токен устройства (для AI-запросов, AIService)
        static let deviceToken = "monpapa.device.token"
        /// UUID устройства (общий для AIService и AuthService)
        static let deviceId    = "monpapa.device.id"
        /// JWT-токен пользователя (для синхронизации, AuthService)
        static let userToken   = "monpapa.user.token"
        /// Email пользователя
        static let userEmail   = "monpapa.user.email"
        /// ID пользователя на сервере
        static let userId      = "monpapa.user.id"
    }
}
