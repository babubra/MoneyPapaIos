// MonPapa iOS — Настройки (Sheet)
//
// Открывается по нажатию на ⚙️ в заголовке DashboardView.
// Стиль: нативный List с секциями и иконками,
// плюс вынос авторизации в отдельный Sheet (AuthCoverView).

import SwiftUI
import SwiftData

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var isAuthPresented = false
    @State private var isLoggingOut = false
    @State private var isDeletingAccount = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var showRestartHint = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: — Профиль (Аккаунт)
                Section {
                    if auth.isAuthenticated {
                        authenticatedProfileView
                    } else {
                        guestProfileView
                    }
                }
                
                // MARK: — Внешний вид
                Section {
                    pickerRow(title: "Тема", icon: "paintbrush.fill", color: .indigo, selection: $settings.appTheme) {
                        Text("Системная").tag("system")
                        Text("Светлая").tag("light")
                        Text("Тёмная").tag("dark")
                    }
                } header: {
                    Text("Внешний вид")
                }
                
                // MARK: — Валюта
                Section {
                    pickerRow(title: String(localized: "settings.currency.default"), icon: "dollarsign.circle.fill", color: .green, selection: $settings.defaultCurrency) {
                        Text("₽ Рубль").tag("RUB")
                        Text("$ Доллар").tag("USD")
                        Text("€ Евро").tag("EUR")
                    }
                } header: {
                    Text("settings.currency.title")
                }

                // MARK: — Язык
                Section {
                    pickerRow(title: String(localized: "settings.language.label"), icon: "globe", color: .teal, selection: $settings.appLanguage) {
                        Text("settings.language.system").tag("system")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }
                    .onChange(of: settings.appLanguage) { _, _ in
                        showRestartHint = true
                    }
                } header: {
                    Text("settings.language.title")
                } footer: {
                    if showRestartHint {
                        Text("settings.language.restartHint")
                            .foregroundColor(MPColors.accentCoral)
                    } else {
                        Text("settings.language.footer")
                    }
                }
                
                // MARK: — Синхронизация
                if auth.isAuthenticated {
                    Section {
                        HStack {
                            settingsIcon("arrow.triangle.2.circlepath", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Облачная синхронизация")
                                switch syncService.status {
                                case .idle:
                                    Text("Готово")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .syncing:
                                    Text("Синхронизация...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .success(let date):
                                    Text("Обновлено: \(date, format: .dateTime.hour().minute())")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                case .error(let msg):
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if syncService.status == .syncing {
                                ProgressView()
                            } else {
                                Button("Sync") {
                                    Task { await syncService.sync() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    } header: {
                        Text("Синхронизация")
                    }
                }
                

                
                // MARK: - Выход
                if auth.isAuthenticated {
                    Section {
                        Button(role: .destructive) {
                            isLoggingOut = true
                            Task {
                                // 1. Принудительная синхронизация — push всех локальных изменений
                                await syncService.sync()
                                // 2. Очищаем локальные данные
                                syncService.clearLocalData()
                                syncService.resetSyncState()
                                // 3. Logout
                                auth.logout()
                                isLoggingOut = false
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoggingOut {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Синхронизация...")
                                } else {
                                    Text("Выйти из аккаунта")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoggingOut || isDeletingAccount)
                    }
                    
                    // MARK: - Удалить аккаунт
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                if isDeletingAccount {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Удаление...")
                                } else {
                                    Text("Удалить аккаунт")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoggingOut || isDeletingAccount)
                    } footer: {
                        Text("Все ваши данные будут безвозвратно удалены с сервера. Это действие невозможно отменить.")
                    }
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
            .sheet(isPresented: $isAuthPresented) {
                AuthCoverView()
            }
            .sheet(isPresented: $showDeleteConfirmation) {
                DeleteAccountConfirmView(
                    isDeleting: $isDeletingAccount,
                    onConfirm: { performDeleteAccount() }
                )
            }
            .alert("Ошибка удаления", isPresented: $showDeleteError) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage)
            }
        }
    }
    
    // MARK: - Удаление аккаунта
    
    private func performDeleteAccount() {
        isDeletingAccount = true
        Task {
            do {
                // 1. Удаляем аккаунт на сервере (каскадно удалит все данные)
                try await auth.deleteAccount()
                // 2. Очищаем локальные данные
                syncService.clearLocalData()
                syncService.resetSyncState()
                // auth.deleteAccount() уже вызывает logout()
            } catch {
                deleteErrorMessage = error.localizedDescription
                showDeleteError = true
            }
            isDeletingAccount = false
        }
    }
    
    // MARK: - Подкомпоненты
    
    private var guestProfileView: some View {
        Button {
            isAuthPresented = true
        } label: {
            HStack(spacing: 16) {
                Circle()
                    .fill(Color(uiColor: .systemGray5))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(MPColors.accentCoral)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Войти в профиль")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Синхронизация и бэкап в облако")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var authenticatedProfileView: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(MPColors.accentCoral.opacity(0.15))
                .frame(width: 60, height: 60)
                .overlay(
                    Text(String(auth.userEmail?.prefix(1).uppercased() ?? "U"))
                        .font(.title2.bold())
                        .foregroundColor(MPColors.accentCoral)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(auth.userEmail ?? "Аккаунт")
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text("Активен")
                    .font(.subheadline)
                    .foregroundColor(MPColors.accentGreen)
            }
        }
        .padding(.vertical, 4)
    }
    
    // Хелперы для красивых строк
    
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: systemName)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            )
    }
    
    private func pickerRow<SelectionValue: Hashable, Content: View>(
        title: String, icon: String, color: Color, selection: Binding<SelectionValue>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        HStack {
            settingsIcon(icon, color: color)
            Picker(title, selection: selection) {
                content()
            }
        }
    }
    
    private func toggleRow(title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        HStack {
            settingsIcon(icon, color: color)
            Toggle(title, isOn: isOn)
        }
    }
}

// MARK: - Подтверждение удаления аккаунта (Bottom Sheet)

struct DeleteAccountConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isDeleting: Bool
    var onConfirm: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                    .padding(.top, 24)
                
                VStack(spacing: 8) {
                    Text("Удалить аккаунт?")
                        .font(.title2.bold())
                    Text("Все транзакции, категории и настройки\nбудут удалены безвозвратно.\nЭто действие невозможно отменить.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                VStack(spacing: 12) {
                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text("Удалить аккаунт и все данные")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .cornerRadius(12)
                    }
                    .disabled(isDeleting)
                    
                    Button {
                        dismiss()
                    } label: {
                        Text("Отмена")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .presentationDetents([.height(340)])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.visible)
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
