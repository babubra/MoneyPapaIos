// MonPapa iOS — Расширения String

import Foundation

extension String {
    /// Капитализация первой буквы строки ("вторник" → "Вторник")
    var capitalizedFirstLetter: String {
        guard let first = self.first else { return self }
        return first.uppercased() + self.dropFirst()
    }
}
