// MonPapa iOS — Настройки приложения через UserDefaults

import SwiftUI
import Combine

// MARK: - AppColorScheme

/// Типобезопасный enum темы приложения.
/// Значение rawValue совпадает со строкой, хранимой в UserDefaults.
enum AppColorScheme: String, CaseIterable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"
}

/// Централизованные настройки приложения.
/// Используют UserDefaults — автоматически сохраняются.
///
/// Использование в View:
/// ```
/// @AppStorage("hideAmounts") var hideAmounts = false
/// Toggle("Скрыть суммы", isOn: $hideAmounts)
/// ```
///
/// Или через синглтон:
/// ```
/// if AppSettings.shared.hideAmounts { ... }
/// ```
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    // MARK: - Внешний вид
    
    /// Тема приложения: "system" / "light" / "dark"
    @Published var appTheme: String {
        didSet { UserDefaults.standard.set(appTheme, forKey: "appTheme") }
    }

    /// Типобезопасный доступ к теме (для Picker в SettingsView)
    var colorScheme: AppColorScheme {
        get { AppColorScheme(rawValue: appTheme) ?? .system }
        set { appTheme = newValue.rawValue }
    }
    
    // MARK: - Приватность
    
    /// Скрывать ли суммы на главном экране (режим конфиденциальности)
    @Published var hideAmounts: Bool {
        didSet { UserDefaults.standard.set(hideAmounts, forKey: "hideAmounts") }
    }
    
    // MARK: - Валюта
    
    /// Валюта по умолчанию
    @Published var defaultCurrency: String {
        didSet { UserDefaults.standard.set(defaultCurrency, forKey: "defaultCurrency") }
    }
    
    // MARK: - AI
    
    /// Самообучение категорий: если пользователь меняет категорию, предложенную AI,
    /// автоматически добавляет подсказку (ai_hint) в выбранную категорию.
    // TODO: Добавить Toggle в экран настроек (SettingsView)
    @Published var aiAutoLearn: Bool {
        didSet { UserDefaults.standard.set(aiAutoLearn, forKey: "aiAutoLearn") }
    }
    
    // MARK: - Инициализатор
    
    init() {
        self.appTheme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
        self.hideAmounts = UserDefaults.standard.bool(forKey: "hideAmounts")
        self.defaultCurrency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "RUB"
        // По умолчанию включено
        self.aiAutoLearn = UserDefaults.standard.object(forKey: "aiAutoLearn") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "aiAutoLearn")
    }
    
    // MARK: - Вычисляемые свойства
    
    /// Предпочтительная цветовая схема для SwiftUI
    var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil  // system
        }
    }
}
