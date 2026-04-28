// MonPapa iOS — Управление языком интерфейса
//
// Вариант A: язык применяется через UserDefaults.AppleLanguages.
// Требует перезапуска приложения для полного эффекта.

import Foundation

enum LocalizationManager {

    /// Поддерживаемые языки интерфейса.
    static let supportedCodes: [String] = ["ru", "en"]

    /// Язык, выбранный пользователем: "system" / "ru" / "en".
    static var currentChoice: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    }

    /// Применяет выбранный язык: пишет `AppleLanguages` так, чтобы при
    /// следующем запуске iOS использовала нужный `.lproj`.
    static func apply(_ choice: String) {
        let defaults = UserDefaults.standard

        switch choice {
        case "ru", "en":
            defaults.set([choice], forKey: "AppleLanguages")
        default:
            // system — удаляем override, iOS вернётся к системной локали
            defaults.removeObject(forKey: "AppleLanguages")
        }

        defaults.synchronize()
    }

    /// Применяет язык при старте приложения. Вызывается как можно раньше в `init`.
    static func applyAtLaunch() {
        apply(currentChoice)
    }

    /// Текущая эффективная локаль приложения для `.environment(\.locale, ...)`.
    /// Используется, чтобы SwiftUI сразу подхватил форматтеры дат/чисел.
    static func effectiveLocale() -> Locale {
        switch currentChoice {
        case "ru": return Locale(identifier: "ru_RU")
        case "en": return Locale(identifier: "en_US")
        default:   return .current
        }
    }
}
