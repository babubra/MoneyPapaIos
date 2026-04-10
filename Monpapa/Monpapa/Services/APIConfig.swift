// MonPapa iOS — Конфигурация API
//
// Единая точка настройки адреса бэкенда.
// Автоматически выбирает нужный сервер в зависимости от среды запуска:
//   • Симулятор (Debug)     → localhost  (для локальной разработки)
//   • Реальное устройство   → VPS        (для тестирования на телефоне)
//   • Release сборка        → Продакшн   (для App Store)

import Foundation

enum APIConfig {

    // MARK: - Базовый URL бэкенда

    static var baseURL: String {
        #if DEBUG
            #if targetEnvironment(simulator)
            // Симулятор видит localhost мака, где запущен Docker
            return "http://localhost:8001"
            #else
            // Реальный iPhone — подключаемся к VPS серверу
            return "http://45.90.99.67:8001"
            #endif
        #else
        // Release (App Store) — продакшн домен
        return "https://api.monpapa.app"  // TODO: заменить, когда будет домен
        #endif
    }
}
