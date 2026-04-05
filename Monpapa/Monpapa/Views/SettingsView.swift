// MonPapa iOS — Настройки (Sheet)
//
// Открывается по нажатию на ⚙️ в заголовке DashboardView.
// Стиль: нативный List с секциями (как старый SettingsPlaceholderView),
// плюс новая секция «Аккаунт» с Magic Link flow.

import SwiftUI

// MARK: - Auth-состояние (конечный автомат)

private enum FocusedField {
    case email, pin
}

private enum AuthStep: Equatable {
    case guest
    case enterEmail
    case enterPin
    case loading
    case authenticated
}

// MARK: - SettingsView

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss

    // Auth flow
    @State private var authStep: AuthStep = .guest
    @FocusState private var focusedField: FocusedField?
    @State private var email = ""
    @State private var pin = ""
    @State private var authError: String? = nil

    // ─────────────────────────────────────────────
    var body: some View {
        NavigationStack {
            List {

                // MARK: — Аккаунт
                accountSection

                // MARK: — Внешний вид
                Section("Внешний вид") {
                    Picker("Тема", selection: $settings.appTheme) {
                        Text("Системная").tag("system")
                        Text("Светлая").tag("light")
                        Text("Тёмная").tag("dark")
                    }

                    Toggle("Скрыть суммы", isOn: $settings.hideAmounts)
                }

                // MARK: — Валюта
                Section("Валюта") {
                    Picker("Валюта по умолчанию", selection: $settings.defaultCurrency) {
                        Text("₽ Рубль").tag("RUB")
                        Text("$ Доллар").tag("USD")
                        Text("€ Евро").tag("EUR")
                    }
                }

                // MARK: — Синхронизация (только для авторизованных)
                if auth.isAuthenticated {
                    syncSection
                }

                // MARK: — AI
                Section("AI") {
                    Toggle("Автообучение категорий", isOn: $settings.aiAutoLearn)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: auth.isAuthenticated) { _, newValue in
                withAnimation {
                    authStep = newValue ? .authenticated : .guest
                }
            }
            .onAppear {
                authStep = auth.isAuthenticated ? .authenticated : .guest
            }
        }
    }

    // MARK: - Секция «Аккаунт»

    @ViewBuilder
    private var accountSection: some View {
        Section {
            switch authStep {
            case .guest:
                guestRow

            case .enterEmail:
                emailInputRows

            case .enterPin:
                pinInputRows

            case .loading:
                HStack {
                    ProgressView()
                        .tint(MPColors.accentCoral)
                    Text("Подождите…")
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }

            case .authenticated:
                authenticatedRows
            }
        } header: {
            Text("Аккаунт")
        } footer: {
            if let err = authError {
                Text(err)
                    .foregroundColor(.red)
            } else if authStep == .enterEmail {
                Text("Мы отправим 6-значный код на указанный email.")
            } else if authStep == .enterPin {
                Text("Введите код из письма. \(email)")
            }
        }
    }

    // ── Не авторизован ────────────────────────────────────────────────

    private var guestRow: some View {
        Button {
            withAnimation { authStep = .enterEmail }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = .email
            }
        } label: {
            Label("Войти по email", systemImage: "envelope.fill")
                .foregroundColor(MPColors.accentCoral)
        }
    }

    // ── Ввод email ────────────────────────────────────────────────────

    @ViewBuilder
    private var emailInputRows: some View {
        #if os(iOS)
        TextField("Email", text: $email)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focusedField, equals: .email)
        #else
        TextField("Email", text: $email)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .email)
        #endif

        Button {
            Task { await requestLink() }
        } label: {
            Label("Отправить код", systemImage: "paperplane.fill")
                .foregroundColor(MPColors.accentCoral)
        }
        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)

        Button(role: .cancel) {
            withAnimation { authStep = .guest; authError = nil; email = "" }
        } label: {
            Label("Отмена", systemImage: "xmark.circle")
                .foregroundColor(.secondary)
        }
    }

    // ── Ввод PIN ──────────────────────────────────────────────────────

    @ViewBuilder
    private var pinInputRows: some View {
        #if os(iOS)
        TextField("6-значный код", text: $pin)
            .keyboardType(.numberPad)
            .focused($focusedField, equals: .pin)
        #else
        TextField("6-значный код", text: $pin)
            .focused($focusedField, equals: .pin)
        #endif

        Button {
            Task { await verifyPin() }
        } label: {
            Label("Подтвердить", systemImage: "checkmark.circle.fill")
                .foregroundColor(MPColors.accentGreen)
        }
        .disabled(pin.trimmingCharacters(in: .whitespaces).count != 6)

        Button {
            withAnimation { authStep = .enterEmail; authError = nil; pin = "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = .pin
            }
        } label: {
            Label("Назад", systemImage: "chevron.left")
                .foregroundColor(MPColors.accentBlue)
        }

        Button {
            Task { await requestLink() }
        } label: {
            Label("Отправить код повторно", systemImage: "arrow.clockwise")
                .foregroundColor(.secondary)
        }
    }

    // ── Авторизован ───────────────────────────────────────────────────

    @ViewBuilder
    private var authenticatedRows: some View {
        HStack {
            Label(auth.userEmail ?? "Аккаунт", systemImage: "checkmark.seal.fill")
                .foregroundColor(.primary)
            Spacer()
            Text("Активен")
                .foregroundColor(.secondary)
                .font(.caption)
        }

        Button(role: .destructive) {
            withAnimation { auth.logout() }
        } label: {
            Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    // MARK: - Секция «Синхронизация»

    private var syncSection: some View {
        Section("Синхронизация") {
            Label("Синхронизировано только что", systemImage: "checkmark.icloud.fill")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Auth логика

    private func requestLink() async {
        let trimmed = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { authError = "Введите корректный email"; return }

        withAnimation { authStep = .loading; authError = nil }

        do {
            try await auth.requestMagicLink(email: trimmed)
            withAnimation {
                authStep = auth.isAuthenticated ? .authenticated : .enterPin
            }
        } catch {
            withAnimation { authStep = .enterEmail; authError = error.localizedDescription }
        }
    }

    private func verifyPin() async {
        let trimmedPin = pin.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard trimmedPin.count == 6 else { authError = "PIN-код должен содержать 6 цифр"; return }

        withAnimation { authStep = .loading; authError = nil }

        do {
            try await auth.verifyPin(email: trimmedEmail, code: trimmedPin)
            withAnimation { authStep = .authenticated }
        } catch {
            withAnimation { authStep = .enterPin; authError = error.localizedDescription }
        }
    }
}

// MARK: - Previews

#Preview("Гость — светлая") {
    SettingsView()
        .environmentObject(AppSettings())
        .preferredColorScheme(.light)
}

#Preview("Гость — тёмная") {
    SettingsView()
        .environmentObject(AppSettings())
        .preferredColorScheme(.dark)
}
