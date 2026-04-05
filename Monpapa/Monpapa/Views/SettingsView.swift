// MonPapa iOS — Настройки (Sheet)
//
// Открывается по нажатию на ⚙️ в заголовке DashboardView.
// Стиль: нативный List с секциями и иконками,
// плюс вынос авторизации в отдельный Sheet (AuthCoverView).

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var isAuthPresented = false

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
                    
                    toggleRow(title: "Скрыть суммы", icon: "eye.slash.fill", color: .gray, isOn: $settings.hideAmounts)
                } header: {
                    Text("Внешний вид")
                }
                
                // MARK: — Валюта
                Section {
                    pickerRow(title: "Валюта по умолчанию", icon: "dollarsign.circle.fill", color: .green, selection: $settings.defaultCurrency) {
                        Text("₽ Рубль").tag("RUB")
                        Text("$ Доллар").tag("USD")
                        Text("€ Евро").tag("EUR")
                    }
                } header: {
                    Text("Валюта")
                }
                
                // MARK: — Синхронизация
                if auth.isAuthenticated {
                    Section {
                        HStack {
                            settingsIcon("arrow.triangle.2.circlepath", color: .blue)
                            Text("Синхронизировано только что")
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Синхронизация")
                    }
                }
                
                // MARK: — AI
                Section {
                    toggleRow(title: "Автообучение категорий", icon: "sparkles", color: .purple, isOn: $settings.aiAutoLearn)
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("Приложение будет запоминать ваши исправления, когда вы меняете предложенную ИИ категорию. Это поможет предлагать более точные категории в будущем.")
                }
                
                // MARK: - Выход
                if auth.isAuthenticated {
                    Section {
                        Button(role: .destructive) {
                            withAnimation { auth.logout() }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Выйти из аккаунта")
                                Spacer()
                            }
                        }
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
