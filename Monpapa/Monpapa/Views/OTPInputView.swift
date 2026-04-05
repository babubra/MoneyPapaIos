import SwiftUI

struct OTPInputView: View {
    @Binding var pin: String
    var length: Int = 6
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ZStack {
            // Скрытый системный TextField, который перехватывает ввод,
            // а также поддерживает AutoFill (из SMS / Почты).
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                // Делаем его невидимым
                .opacity(0)
                .frame(width: 1, height: 1)
                // Ограничиваем длину
                .onChange(of: pin) { _, newValue in
                    if newValue.count > length {
                        pin = String(newValue.prefix(length))
                    }
                }
            
            // Видимые квадратики для ПИН-кода
            HStack(spacing: 12) {
                ForEach(0..<length, id: \.self) { index in
                    ZStack {
                        let isCurrentIndex = index == pin.count
                        let hasDigit = index < pin.count
                        
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isCurrentIndex && isFocused ? MPColors.accentCoral :
                                    hasDigit ? Color.primary.opacity(0.4) : Color.secondary.opacity(0.2),
                                lineWidth: isCurrentIndex && isFocused ? 2 : 1
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(uiColor: .systemLevel2 ?? .secondarySystemBackground))
                            )
                            .frame(width: 44, height: 52)
                            .shadow(color: isCurrentIndex && isFocused ? MPColors.accentCoral.opacity(0.3) : .clear, radius: 4, x: 0, y: 2)
                        
                        if hasDigit {
                            let charIndex = pin.index(pin.startIndex, offsetBy: index)
                            Text(String(pin[charIndex]))
                                .font(.title)
                                .fontWeight(.medium)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pin)
                    .animation(.easeInOut(duration: 0.2), value: isFocused)
                }
            }
            .onTapGesture {
                isFocused = true
            }
            .contentShape(Rectangle())
            .onAppear {
                isFocused = true
            }
        }
    }
}

// Заглушка для совместимости со старыми версиями
extension UIColor {
    static var systemLevel2: UIColor? {
        // Попытка использовать третичный фон в качестве более темного/светлого
        return .secondarySystemBackground
    }
}
