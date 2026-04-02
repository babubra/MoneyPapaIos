// MonPapa iOS — Модификатор для скрытия клавиатуры при тапе

import SwiftUI

/// Модификатор, который скрывает клавиатуру при тапе вне поля ввода
struct DismissKeyboardOnTap: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
    }
}

extension View {
    /// Скрывает клавиатуру при тапе на область этого View
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTap())
    }
}
