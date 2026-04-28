import SwiftUI
import Combine

struct AuthCoverView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject private var auth = AuthService.shared
    
    @State private var email = ""
    @State private var pin = ""
    @State private var step: AuthStep = .enterEmail
    @State private var authError: String? = nil
    
    // Таймер блокировки повторной отправки
    @State private var cooldownSeconds = 0
    
    private enum AuthStep {
        case enterEmail, loading, enterPin
    }
    
    private var isEmailValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return false }
        // Строгая валидация формата почты
        let regex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
        return predicate.evaluate(with: trimmed)
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                switch step {
                case .enterEmail:
                    emailView
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .enterPin:
                    pinView
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .loading:
                    loadingView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: step)
            .navigationTitle(step == .enterEmail ? "Вход" : "Подтверждение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .enterPin {
                        Button("Назад") {
                            withAnimation {
                                step = .enterEmail
                                pin = ""
                                authError = nil
                            }
                        }
                    } else {
                        Button("Отмена") { dismiss() }
                    }
                }
            }
            .onChange(of: auth.isAuthenticated) { _, newValue in
                if newValue {
                    // Авторизация прошла — запускаем синхронизацию и закрываем экран
                    Task { await syncService.sync() }
                    dismiss()
                }
            }
            // Обработчик таймера для кулдауна
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if cooldownSeconds > 0 {
                    cooldownSeconds -= 1
                }
            }
        }
        .presentationDetents([.height(380), .medium])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Email View
    private var emailView: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundColor(MPColors.accentCoral)
                .padding(.top, 24)
            
            VStack(spacing: 8) {
                Text("Войдите по Magic Link")
                    .font(.title2.bold())
                Text("Мы отправим одноразовый код\nна ваш email.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "envelope")
                        .foregroundColor(.secondary)
                    TextField("Ваш Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding()
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
                
                if let error = authError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
            
            Button {
                Task { await requestLink() }
            } label: {
                Text("Получить код")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(!isEmailValid ? Color.gray.opacity(0.4) : MPColors.accentCoral)
                    .cornerRadius(12)
            }
            .disabled(!isEmailValid)
            .padding(.horizontal)
            
            Spacer()
        }
    }
    
    // MARK: - PIN View
    private var pinView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(MPColors.accentCoral)
                .padding(.top, 24)
            
            VStack(spacing: 4) {
                Text("Введите код")
                    .font(.title2.bold())
                    .padding(.bottom, 4)
                
                Text("Код отправлен на:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(email)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            
            OTPInputView(pin: $pin)
                .padding(.vertical, 8)
                .onChange(of: pin) { _, newValue in
                    if newValue.count == 6 {
                        Task { await verifyPin() }
                    }
                }
            
            if let error = authError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
            
            // Кнопка повторной отправки с таймером
            Button {
                Task { await requestLink() }
            } label: {
                Text(cooldownSeconds > 0 ? "Отправить повторно через \(cooldownSeconds) сек" : "Отправить код повторно")
            }
            .font(.footnote)
            .foregroundColor(cooldownSeconds > 0 ? .secondary.opacity(0.5) : .secondary)
            .disabled(cooldownSeconds > 0)
            .padding(.top, 8)
            
            Spacer()
        }
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(MPColors.accentCoral)
            Text("Пожалуйста, подождите...")
                .foregroundColor(.secondary)
                .padding(.top, 16)
            Spacer()
        }
    }
    
    // MARK: - Actions
    private func requestLink() async {
        let trimmed = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard isEmailValid else { authError = "Введите корректный email"; return }
        
        print("[AuthCover] 📧 requestLink START: email=\(trimmed)")
        print("[AuthCover] 📧 auth.isAuthenticated BEFORE = \(auth.isAuthenticated)")
        
        // Запоминаем состояние ДО вызова — Keychain может хранить стейл-токен
        let wasAuthenticated = auth.isAuthenticated
        
        withAnimation { step = .loading; authError = nil }
        
        do {
            try await auth.requestMagicLink(email: trimmed)
            
            let nowAuthenticated = auth.isAuthenticated
            print("[AuthCover] ✅ requestMagicLink вернулся без ошибки")
            print("[AuthCover] 📧 auth.isAuthenticated AFTER = \(nowAuthenticated)")
            
            // DEV_MODE: если requestMagicLink ИЗМЕНИЛ isAuthenticated с false→true
            // Если isAuthenticated был true И ДО вызова (стейл-токен), идём на enterPin
            if nowAuthenticated && !wasAuthenticated {
                // DEV_MODE авторизовал напрямую — onChange сам закроет экран
                print("[AuthCover] 📧 DEV_MODE: авторизация прямая, step остаётся")
            } else {
                // Обычный режим: всегда переходим на ввод PIN
                print("[AuthCover] 📧 Переход на шаг: enterPin")
                withAnimation { step = .enterPin }
            }
            
            // Включаем кулдаун в 60 секунд после успешной отправки
            cooldownSeconds = 60
        } catch {
            print("[AuthCover] ❌ requestLink ОШИБКА: \(error)")
            print("[AuthCover] ❌ error.localizedDescription: \(error.localizedDescription)")
            withAnimation { step = .enterEmail; authError = error.localizedDescription }
        }
    }
    
    private func verifyPin() async {
        let trimmedPin = pin.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard trimmedPin.count == 6 else { authError = "PIN-код должен содержать 6 цифр"; return }
        
        print("[AuthCover] 🔑 verifyPin START: email=\(trimmedEmail), pin=\(trimmedPin)")
        
        withAnimation { step = .loading; authError = nil }
        
        do {
            try await auth.verifyPin(email: trimmedEmail, code: trimmedPin)
            print("[AuthCover] ✅ verifyPin SUCCESS, isAuthenticated=\(auth.isAuthenticated)")
        } catch {
            print("[AuthCover] ❌ verifyPin ОШИБКА: \(error)")
            print("[AuthCover] ❌ error.localizedDescription: \(error.localizedDescription)")
            withAnimation { step = .enterPin; authError = error.localizedDescription }
        }
    }
}
