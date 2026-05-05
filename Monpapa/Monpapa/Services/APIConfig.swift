// MonPapa iOS — Конфигурация API
//
// Единая точка настройки адреса бэкенда. Логика:
//
//   • Симулятор iOS (Debug)   → http://localhost:8001
//     (симулятор шарит сеть с Mac, локальный Docker `cd backend && docker compose up`
//      слушает 0.0.0.0:8001 → доступен по localhost)
//
//   • Реальное iPhone (Debug) → IP Mac в Wi-Fi (например 192.168.x.x:8001)
//     ИЛИ адрес staging-VPS, когда он появится. Сейчас поставлен placeholder
//     (см. ниже DEVICE_DEBUG_URL) — измени под свою сеть, либо тестируй через
//     симулятор. Прежний прод-VPS (45.90.99.67) намеренно убран — там старый
//     код, несовместимый с Auth Model C.
//
//   • Release (App Store)     → https://api.monpapa.app (поднимется на новом
//     production-VPS перед публикацией).
//
// Чтобы переключить устройство-Debug — поправь DEVICE_DEBUG_URL ниже.

import Foundation

enum APIConfig {

    // MARK: - Базовый URL бэкенда

    /// Адрес для Debug-сборки на физическом устройстве. По умолчанию — заглушка,
    /// меняется вручную под локальную Wi-Fi сеть, когда появится staging-VPS.
    /// Симулятор сюда НЕ ходит — у него отдельная ветка ниже (localhost).
    private static let DEVICE_DEBUG_URL = "http://192.168.1.1:8001"  // TODO: заменить на IP Mac или staging-VPS

    static var baseURL: String {
        #if DEBUG
        #if targetEnvironment(simulator)
        // iOS-симулятор шарит сеть с Mac → локальный Docker доступен напрямую.
        return "http://localhost:8001"
        #else
        // Реальное устройство — настрой под свою сеть.
        return DEVICE_DEBUG_URL
        #endif
        #else
        // Release (App Store) — продакшн домен.
        return "https://api.monpapa.app"  // TODO: заменить, когда будет домен
        #endif
    }
}
