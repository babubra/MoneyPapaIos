// MonPapa iOS — Создание новой категории (Экран 3)

import SwiftUI
import SwiftData

struct CreateCategoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    /// Предзаполненный тип из формы транзакции
    var initialType: TransactionType
    
    /// Callback: вернуть созданную категорию в picker
    var onCreated: ((CategoryModel) -> Void)?
    
    // MARK: - Поля формы
    
    @State private var icon = ""
    @State private var name = ""
    @State private var categoryType: TransactionType = .expense
    @State private var selectedExpenseParent: CategoryModel?
    @State private var selectedIncomeParent: CategoryModel?
    @State private var aiHint = ""
    
    /// Текущий родитель в зависимости от типа
    private var selectedParent: CategoryModel? {
        switch categoryType {
        case .expense: selectedExpenseParent
        case .income: selectedIncomeParent
        }
    }
    
    /// Binding для Picker
    private var parentBinding: Binding<CategoryModel?> {
        switch categoryType {
        case .expense: $selectedExpenseParent
        case .income: $selectedIncomeParent
        }
    }
    
    // MARK: - UI State
    
    @FocusState private var focusedField: Field?
    @State private var showDuplicateWarning = false
    @State private var showSaveError = false
    @State private var showEmojiPicker = false
    
    private enum Field {
        case name, aiHint
    }
    
    // MARK: - Данные
    
    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil }, sort: \CategoryModel.name)
    private var allCategories: [CategoryModel]
    
    /// Корневые категории того же типа (для выбора родителя)
    private var availableParents: [CategoryModel] {
        allCategories.filter { $0.type == categoryType && $0.parent == nil }
    }
    
    // MARK: - Валидация
    
    /// Имя не пустое
    private var hasValidName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Категория с таким именем и типом уже существует
    private var isDuplicate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return allCategories.contains {
            $0.name.lowercased() == trimmed && $0.type == categoryType
        }
    }
    
    /// Можно ли сохранить
    private var canSave: Bool {
        hasValidName && !isDuplicate
    }
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: MPSpacing.lg) {
                    // MARK: — Emoji + Название
                    iconAndNameSection
                    
                    // MARK: — Тип (расход / доход)
                    typeSection
                    
                    // MARK: — Карточка: Родитель + AI-подсказка
                    detailsCard
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.top, MPSpacing.sm)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
        }
        .navigationTitle("Новая категория")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }
                    .foregroundColor(MPColors.accentCoral)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Создать") { saveCategory() }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(canSave ? MPColors.accentCoral : MPColors.textSecondary)
                    .disabled(!canSave)
            }
        }
        .onAppear {
            categoryType = initialType
        }
        .alert("Ошибка", isPresented: $showSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Не удалось сохранить категорию. Попробуйте ещё раз.")
        }
    }
    
    // MARK: - Emoji иконка + Название
    
    private var iconAndNameSection: some View {
        HStack(spacing: MPSpacing.md) {
            // Emoji кнопка
            Button {
                focusedField = nil // Скрываем клавиатуру
                showEmojiPicker = true
            } label: {
                ZStack {
                    Circle()
                        .fill(MPColors.cardBackground)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .stroke(MPColors.separator, lineWidth: 1)
                        )
                    
                    if icon.isEmpty {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 24))
                            .foregroundColor(MPColors.textSecondary.opacity(0.5))
                    } else {
                        Text(icon)
                            .font(.system(size: 30))
                    }
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showEmojiPicker) {
                EmojiPickerView(selectedEmoji: $icon)
                    .presentationDetents([.medium, .large])
            }
            
            // Поле названия
            VStack(alignment: .leading, spacing: MPSpacing.xxs) {
                TextField("Название категории", text: $name)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textPrimary)
                    .focused($focusedField, equals: .name)
                    .onChange(of: name) { _, _ in
                        // Сбрасываем предупреждение при редактировании
                        showDuplicateWarning = false
                    }
                
                // Предупреждение о дубликате
                if isDuplicate && showDuplicateWarning {
                    Label("Категория с таким именем уже существует", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(MPSpacing.md)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }
    
    // MARK: - Тип категории
    
    private var typeSection: some View {
        typeSegment
    }
    
    /// Цвет активного сегмента
    private var segmentColor: Color {
        categoryType == .expense
            ? MPColors.accentCoral
            : MPColors.accentGreen
    }
    
    private var typeSegment: some View {
        HStack(spacing: 4) {
            segmentButton(title: "Расход", type: .expense, color: MPColors.accentCoral)
            segmentButton(title: "Доход", type: .income, color: MPColors.accentGreen)
        }
        .padding(4)
        .background(
            MPColors.cardBackground.opacity(0.6)
        )
        .cornerRadius(MPCornerRadius.pill)
    }
    
    private func segmentButton(title: String, type: TransactionType, color: Color) -> some View {
        let isSelected = categoryType == type
        
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                categoryType = type
            }
        } label: {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? .white : MPColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm)
                .background(
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: MPCornerRadius.pill - 2)
                                .fill(
                                    LinearGradient(
                                        colors: [color.opacity(0.9), color.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            RoundedRectangle(cornerRadius: MPCornerRadius.pill - 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.3), .clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        }
                    }
                )
                .cornerRadius(MPCornerRadius.pill - 2)
                .contentShape(Rectangle())
                .shadow(
                    color: isSelected ? color.opacity(0.5) : .clear,
                    radius: isSelected ? 12 : 0
                )
                .shadow(
                    color: isSelected ? color.opacity(0.3) : .clear,
                    radius: isSelected ? 20 : 0,
                    x: 0, y: 4
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Карточка деталей (Родитель + AI-подсказка)
    
    private var detailsCard: some View {
        VStack(spacing: 0) {
            
            // 📂 Родительская категория
            Menu {
                Button {
                    parentBinding.wrappedValue = nil
                } label: {
                    if selectedParent == nil {
                        Label("Без родителя", systemImage: "checkmark")
                    } else {
                        Text("Без родителя")
                    }
                }
                
                ForEach(availableParents, id: \.name) { parent in
                    Button {
                        parentBinding.wrappedValue = parent
                    } label: {
                        let label = [parent.effectiveIcon, parent.name]
                            .compactMap { $0 }
                            .joined(separator: " ")
                        if selectedParent?.name == parent.name {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack(spacing: MPSpacing.sm) {
                    if let parent = selectedParent {
                        // Выбран: иконка (если есть) + название
                        if let icon = parent.effectiveIcon {
                            Text(icon)
                                .font(.system(size: 20))
                                .frame(width: 28)
                        }
                        
                        Text(parent.name)
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                            .lineLimit(1)
                    } else {
                        // Не выбран: статичный лейбл + placeholder
                        Text("📂")
                            .font(.system(size: 20))
                            .frame(width: 28)
                        
                        Text("Родитель")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textPrimary)
                    }
                    
                    Spacer()
                    
                    if selectedParent == nil {
                        Text("Выберите")
                            .font(MPTypography.body)
                            .foregroundColor(MPColors.textSecondary)
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MPColors.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.vertical, MPSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Divider()
                .padding(.leading, MPSpacing.md)
            
            // 🤖 Подсказка для AI — заголовок сверху, TextEditor снизу
            VStack(alignment: .leading, spacing: MPSpacing.xxs) {
                Text("Подсказка для AI")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MPColors.textSecondary)
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                
                ZStack(alignment: .topLeading) {
                    if aiHint.isEmpty {
                        Text("Сюда относятся покупки в кофейнях...")
                            .font(MPTypography.caption)
                            .foregroundColor(MPColors.textSecondary.opacity(0.5))
                            .padding(.horizontal, MPSpacing.md - MPSpacing.xxs)
                            .padding(.vertical, MPSpacing.xxs + 1)
                            .allowsHitTesting(false)
                    }
                    
                    TextEditor(text: $aiHint)
                        .font(MPTypography.caption)
                        .foregroundColor(MPColors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .aiHint)
                        .frame(minHeight: 50, maxHeight: 80)
                        .padding(.horizontal, MPSpacing.md - MPSpacing.xxs)
                        .padding(.bottom, MPSpacing.xs)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }
    
    // MARK: - Сохранение
    
    private func saveCategory() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Проверка дубликата
        if isDuplicate {
            withAnimation(.spring(response: 0.3)) {
                showDuplicateWarning = true
            }
            // Haptic — ошибка
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            return
        }
        
        let category = CategoryModel(
            name: trimmedName,
            type: categoryType,
            icon: icon.isEmpty ? nil : icon,
            aiHint: aiHint.isEmpty ? nil : aiHint,
            parent: selectedParent
        )
        
        modelContext.insert(category)
        
        do {
            try modelContext.save()
            // Haptic — успех
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            // Триггер автосинхронизации
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            onCreated?(category)
            dismiss()
        } catch {
            // Откатываем вставку при ошибке
            modelContext.delete(category)
            showSaveError = true
            print("❌ Ошибка сохранения категории: \(error)")
        }
    }
}

// MARK: - Preview

#Preview("Создать категорию — тёмная") {
    NavigationStack {
        CreateCategoryView(initialType: .expense)
    }
    .modelContainer(for: [
        CategoryModel.self,
        TransactionModel.self,
        CounterpartModel.self,
        DebtModel.self,
        DebtPaymentModel.self,
    ], inMemory: true)
    .preferredColorScheme(.dark)
}

#Preview("Создать категорию — светлая") {
    NavigationStack {
        CreateCategoryView(initialType: .income)
    }
    .modelContainer(for: [
        CategoryModel.self,
        TransactionModel.self,
        CounterpartModel.self,
        DebtModel.self,
        DebtPaymentModel.self,
    ], inMemory: true)
    .preferredColorScheme(.light)
}
