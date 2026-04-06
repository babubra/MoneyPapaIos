// MonPapa iOS — Экран выбора категории (Экран 2)

import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Binding var selectedCategory: CategoryModel?
    var transactionType: TransactionType
    
    /// Вызывается когда нужно закрыть весь stack sheet'ов разом (после создания категории)
    var onDismissAll: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil }, sort: \CategoryModel.name)
    private var allCategories: [CategoryModel]
    
    @State private var searchText = ""
    @State private var showCreateCategory = false
    
    // MARK: - Фильтрация
    
    /// Корневые категории нужного типа
    private var rootCategories: [CategoryModel] {
        allCategories.filter { $0.type == transactionType && $0.parent == nil }
    }
    
    /// Поиск по всем категориям (плоский список)
    private var searchResults: [CategoryModel] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return allCategories.filter {
            $0.type == transactionType &&
            $0.name.lowercased().contains(query)
        }
    }
    
    /// Режим поиска активен?
    private var isSearching: Bool {
        !searchText.isEmpty
    }
    
    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: MPSpacing.sm) {
                    // MARK: - Кнопка «+ Создать категорию»
                    createCategoryButton
                    
                    // MARK: - Список категорий
                    if isSearching {
                        // Плоский список результатов поиска
                        searchResultsList
                    } else {
                        // Иерархический список
                        categoriesHierarchy
                    }
                }
                .padding(.horizontal, MPSpacing.md)
                .padding(.top, MPSpacing.sm)
            }
        }
        .navigationTitle("Категория")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Найти категорию"
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }
                    .foregroundColor(MPColors.accentCoral)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
                    .foregroundColor(MPColors.accentCoral)
            }
        }
        .navigationDestination(isPresented: $showCreateCategory) {
            CreateCategoryView(
                initialType: transactionType,
                onCreated: { newCategory in
                    if newCategory.type == transactionType {
                        selectedCategory = newCategory
                        // Закрываем весь sheet одной анимацией вместо двух последовательных dismiss
                        if let onDismissAll {
                            onDismissAll()
                        } else {
                            dismiss()
                        }
                    }
                    // Иначе — категория сохранена, но тип не совпадает — остаёмся
                }
            )
        }
    }
    
    // MARK: - Кнопка «+ Создать»
    
    private var createCategoryButton: some View {
        Button {
            showCreateCategory = true
        } label: {
            HStack(spacing: MPSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(MPColors.accentCoral.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(MPColors.accentCoral)
                }
                
                Text("Создать категорию")
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.accentCoral)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MPColors.accentCoral.opacity(0.5))
            }
            .padding(.horizontal, MPSpacing.md)
            .padding(.vertical, MPSpacing.sm)
            .background(MPColors.cardBackground)
            .cornerRadius(MPCornerRadius.lg)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Иерархический список
    
    private var categoriesHierarchy: some View {
        VStack(spacing: 0) {
            ForEach(Array(rootCategories.enumerated()), id: \.element.name) { index, category in
                // Строка категории
                categoryRow(category)
                
                // Дочерние категории (если есть)
                if !category.children.isEmpty {
                    ForEach(category.children, id: \.name) { child in
                        childCategoryRow(child)
                        
                        if child.name != category.children.last?.name {
                            Divider()
                                .padding(.leading, 76)
                        }
                    }
                }
                
                // Разделитель между корневыми (не после последней)
                if index < rootCategories.count - 1 {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }
    
    // MARK: - Результаты поиска
    
    private var searchResultsList: some View {
        VStack(spacing: 0) {
            if searchResults.isEmpty {
                // Пустой результат
                VStack(spacing: MPSpacing.sm) {
                    Text("🔍")
                        .font(.system(size: 36))
                    Text("Ничего не найдено")
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textSecondary)
                    Text("Попробуйте другой запрос\nили создайте новую категорию")
                        .font(MPTypography.caption)
                        .foregroundColor(MPColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.xl)
            } else {
                ForEach(Array(searchResults.enumerated()), id: \.element.name) { index, category in
                    categoryRow(category)
                    
                    if index < searchResults.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }
    
    // MARK: - Строка категории (корневая)
    
    private func categoryRow(_ category: CategoryModel) -> some View {
        let isSelected = selectedCategory?.name == category.name
        
        return Button {
            selectedCategory = category
            dismiss()
        } label: {
            HStack(spacing: MPSpacing.sm) {
                // Emoji иконка (только если есть)
                if let icon = category.effectiveIcon {
                    Text(icon)
                        .font(.system(size: 26))
                        .frame(width: 36, height: 36)
                }
                
                // Название
                Text(category.name)
                    .font(MPTypography.body)
                    .foregroundColor(MPColors.textPrimary)
                
                Spacer()
                
                // Чекмарк выбранной
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(MPColors.accentCoral)
                }
            }
            .padding(.horizontal, MPSpacing.md)
            .padding(.vertical, MPSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Строка дочерней категории
    
    private func childCategoryRow(_ category: CategoryModel) -> some View {
        let isSelected = selectedCategory?.name == category.name
        
        return Button {
            selectedCategory = category
            dismiss()
        } label: {
            HStack(spacing: MPSpacing.sm) {
                // Иконка поменьше (только если есть)
                if let icon = category.effectiveIcon {
                    Text(icon)
                        .font(.system(size: 20))
                        .frame(width: 28, height: 28)
                }
                
                Text(category.name)
                    .font(MPTypography.caption)
                    .foregroundColor(MPColors.textPrimary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(MPColors.accentCoral)
                }
            }
            .padding(.leading, MPSpacing.md + 36 + MPSpacing.sm)
            .padding(.trailing, MPSpacing.md)
            .padding(.vertical, MPSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview с демо-данными

#Preview("Выбор категории — расходы") {
    NavigationStack {
        CategoryPickerPreviewWrapper(type: .expense)
    }
    .preferredColorScheme(.dark)
}

#Preview("Выбор категории — доходы") {
    NavigationStack {
        CategoryPickerPreviewWrapper(type: .income)
    }
    .preferredColorScheme(.dark)
}

/// Обёртка для Preview c seed-данными
private struct CategoryPickerPreviewWrapper: View {
    let type: TransactionType
    @State private var selected: CategoryModel?
    
    var body: some View {
        CategoryPickerView(
            selectedCategory: $selected,
            transactionType: type
        )
        .modelContainer(previewContainer)
    }
    
    /// Контейнер с предзаполненными категориями
    var previewContainer: ModelContainer {
        let container = try! ModelContainer(
            for: CategoryModel.self, TransactionModel.self,
                 CounterpartModel.self, DebtModel.self, DebtPaymentModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        
        // Расходные категории
        let food = CategoryModel(name: "Продукты", type: .expense, icon: "🛒")
        let cafe = CategoryModel(name: "Кафе и рестораны", type: .expense, icon: "🍕")
        let transport = CategoryModel(name: "Транспорт", type: .expense, icon: "🚗")
        let entertainment = CategoryModel(name: "Развлечения", type: .expense, icon: "🎬")
        let health = CategoryModel(name: "Здоровье", type: .expense, icon: "💊")
        let clothes = CategoryModel(name: "Одежда", type: .expense, icon: "👕")
        let home = CategoryModel(name: "Дом и ремонт", type: .expense, icon: "🏠")
        let gifts = CategoryModel(name: "Подарки", type: .expense, icon: "🎁")
        let utilities = CategoryModel(name: "Коммунальные", type: .expense, icon: "💡")
        let phone = CategoryModel(name: "Связь и интернет", type: .expense, icon: "📱")
        let education = CategoryModel(name: "Образование", type: .expense, icon: "📚")
        let other = CategoryModel(name: "Прочие расходы", type: .expense, icon: "📦")
        
        // Дочерние категории для «Транспорт»
        let taxi = CategoryModel(name: "Такси", type: .expense, icon: "🚕", parent: transport)
        let metro = CategoryModel(name: "Метро", type: .expense, icon: "🚇", parent: transport)
        let fuel = CategoryModel(name: "Бензин", type: .expense, icon: "⛽", parent: transport)

        // Дочерние для «Кафе»
        let coffee = CategoryModel(name: "Кофе", type: .expense, icon: "☕", parent: cafe)
        let delivery = CategoryModel(name: "Доставка еды", type: .expense, icon: "🛵", parent: cafe)
        
        // Доходные
        let salary = CategoryModel(name: "Зарплата", type: .income, icon: "💰")
        let freelance = CategoryModel(name: "Фриланс", type: .income, icon: "💻")
        let incomeGifts = CategoryModel(name: "Подарки", type: .income, icon: "🎉")
        let otherIncome = CategoryModel(name: "Прочие доходы", type: .income, icon: "📈")
        
        for cat in [food, cafe, transport, entertainment, health, clothes,
                     home, gifts, utilities, phone, education, other,
                     taxi, metro, fuel, coffee, delivery,
                     salary, freelance, incomeGifts, otherIncome] {
            context.insert(cat)
        }
        
        return container
    }
}
