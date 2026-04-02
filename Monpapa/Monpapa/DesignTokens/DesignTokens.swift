
//  DesignTokens.swift
//  Monpapa
//
//  Дизайн-система MonPapa — уютное семейное финансовое приложение
//

import SwiftUI

// MARK: - Цвета

/// Центральное хранилище всех цветов приложения.
/// Поддерживает автоматическое переключение тёмной/светлой тёмы.
struct MPColors {
    
    // MARK: Фоны
    
    /// Основной фон приложения
    static let background = Color("MPBackground")
    
    /// Фон карточек, полей ввода, модальных окон
    static let cardBackground = Color("MPCardBackground")
    
    // MARK: Текст
    
    /// Основной текст
    static let textPrimary = Color("MPTextPrimary")
    
    /// Вторичный текст, плейсхолдеры, подсказки
    static let textSecondary = Color("MPTextSecondary")
    
    // MARK: Акцентные цвета
    
    /// Коралловый — основные кнопки действия
    static let accentCoral = Color("MPAccentCoral")
    
    /// Жёлтый — акценты, бордеры полей, декор
    static let accentYellow = Color("MPAccentYellow")
    
    /// Бирюзово-синий — ссылки, иконки, декор
    static let accentBlue = Color("MPAccentBlue")
    
    /// Зелёный — успех, декор, позитивные суммы
    static let accentGreen = Color("MPAccentGreen")
    
    // MARK: Разделители и границы
    
    /// Разделители, бордеры
    static let separator = Color("MPSeparator")
}

// MARK: - Типографика

/// Стили текста для всего приложения
struct MPTypography {
    
    /// Название приложения (MonPapa) — 32pt Bold Rounded
    static let appTitle = Font.system(size: 32, weight: .bold, design: .rounded)
    
    /// Подзаголовок (Семейные финансы) — 16pt Regular
    static let subtitle = Font.system(size: 16, weight: .regular, design: .rounded)
    
    /// Заголовок экрана — 24pt Bold Rounded
    static let screenTitle = Font.system(size: 24, weight: .bold, design: .rounded)
    
    /// Текст кнопки — 17pt Semibold
    static let button = Font.system(size: 17, weight: .semibold, design: .rounded)
    
    /// Текст поля ввода — 16pt Regular
    static let input = Font.system(size: 16, weight: .regular, design: .default)
    
    /// Лейбл поля ввода — 12pt Regular
    static let inputLabel = Font.system(size: 12, weight: .regular, design: .default)
    
    /// Основной текст — 16pt Regular
    static let body = Font.system(size: 16, weight: .regular, design: .default)
    
    /// Мелкий текст / ссылки — 14pt Regular
    static let caption = Font.system(size: 14, weight: .regular, design: .default)
    
    /// Мелкий текст / ссылки — 14pt Semibold
    static let captionBold = Font.system(size: 14, weight: .semibold, design: .default)
}

// MARK: - Размеры и отступы

/// Стандартные размеры и отступы
struct MPSpacing {
    /// 4pt
    static let xxs: CGFloat = 4
    /// 8pt
    static let xs: CGFloat = 8
    /// 12pt
    static let sm: CGFloat = 12
    /// 16pt
    static let md: CGFloat = 16
    /// 24pt
    static let lg: CGFloat = 24
    /// 32pt
    static let xl: CGFloat = 32
    /// 48pt
    static let xxl: CGFloat = 48
}

// MARK: - Скругления

/// Стандартные радиусы скругления
struct MPCornerRadius {
    /// Маленькое скругление — 8pt (мелкие элементы)
    static let sm: CGFloat = 8
    /// Среднее скругление — 12pt (карточки, кнопки)
    static let md: CGFloat = 12
    /// Большое скругление — 16pt (модальные окна)
    static let lg: CGFloat = 16
    /// Pill-shape — 24pt (кнопки, поля ввода)
    static let pill: CGFloat = 24
    /// Максимальное — 32pt
    static let full: CGFloat = 32
}
