// MonPapa iOS — Фильтр по категориям (мультивыбор с чекбоксами)

import SwiftUI
import SwiftData

struct CategoryFilterView: View {
    /// Набор clientId выбранных категорий
    @Binding var selectedCategoryIds: Set<String>

    /// Тип транзакции для фильтрации списка категорий (nil = все)
    var transactionType: TransactionType?

    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<CategoryModel> { $0.deletedAt == nil }, sort: \CategoryModel.name)
    private var allCategories: [CategoryModel]

    @State private var searchText = ""

    // MARK: - Фильтрация

    /// Корневые категории нужного типа
    private var rootCategories: [CategoryModel] {
        allCategories.filter { cat in
            cat.parent == nil &&
            (transactionType == nil || cat.type == transactionType)
        }
    }

    /// Результаты поиска
    private var searchResults: [CategoryModel] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return allCategories.filter { cat in
            (transactionType == nil || cat.type == transactionType) &&
            cat.name.lowercased().contains(query)
        }
    }

    private var isSearching: Bool {
        !searchText.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MPSpacing.sm) {
                        // Поиск
                        searchBar

                        // Список
                        if isSearching {
                            searchResultsSection
                        } else {
                            hierarchySection
                        }

                        // Сбросить
                        if !selectedCategoryIds.isEmpty {
                            resetButton
                                .padding(.top, MPSpacing.sm)
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.top, MPSpacing.sm)
                    .padding(.bottom, MPSpacing.xl)
                }
            }
            .navigationTitle("Фильтр по категориям")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
            }
        }
    }

    // MARK: - Поиск

    private var searchBar: some View {
        HStack(spacing: MPSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(MPColors.textSecondary)

            TextField("Поиск категории...", text: $searchText)
                .font(MPTypography.body)
                .foregroundColor(MPColors.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(MPColors.textSecondary)
                }
            }
        }
        .padding(.horizontal, MPSpacing.sm)
        .padding(.vertical, MPSpacing.xs + 2)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }

    // MARK: - Иерархический список

    private var hierarchySection: some View {
        VStack(spacing: 0) {
            ForEach(Array(rootCategories.enumerated()), id: \.element.name) { index, category in
                // Корневая категория
                checkboxRow(category: category, isChild: false)

                // Дочерние
                if !category.children.isEmpty {
                    ForEach(category.children.filter { $0.deletedAt == nil }, id: \.name) { child in
                        checkboxRow(category: child, isChild: true)
                    }
                }

                // Разделитель
                if index < rootCategories.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Результаты поиска

    private var searchResultsSection: some View {
        VStack(spacing: 0) {
            if searchResults.isEmpty {
                VStack(spacing: MPSpacing.sm) {
                    Text("🔍")
                        .font(.system(size: 36))
                    Text("Ничего не найдено")
                        .font(MPTypography.body)
                        .foregroundColor(MPColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.xl)
            } else {
                ForEach(Array(searchResults.enumerated()), id: \.element.name) { index, category in
                    checkboxRow(category: category, isChild: false)
                    if index < searchResults.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.lg)
    }

    // MARK: - Строка с чекбоксом

    private func checkboxRow(category: CategoryModel, isChild: Bool) -> some View {
        let catId = category.clientId ?? ""
        let isSelected = selectedCategoryIds.contains(catId)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected {
                    selectedCategoryIds.remove(catId)
                } else {
                    selectedCategoryIds.insert(catId)
                }

                // Если это parent — переключаем и все дочерние
                if !isChild {
                    let childIds = category.children
                        .filter { $0.deletedAt == nil }
                        .compactMap(\.clientId)

                    if isSelected {
                        for id in childIds { selectedCategoryIds.remove(id) }
                    } else {
                        for id in childIds { selectedCategoryIds.insert(id) }
                    }
                }
            }
        } label: {
            HStack(spacing: MPSpacing.sm) {
                // Чекбокс
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? MPColors.accentCoral : MPColors.textSecondary)

                // Emoji
                if let icon = category.effectiveIcon {
                    Text(icon)
                        .font(.system(size: isChild ? 20 : 26))
                        .frame(width: isChild ? 28 : 36, height: isChild ? 28 : 36)
                }

                // Название
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.name)
                        .font(isChild ? MPTypography.caption : MPTypography.body)
                        .foregroundColor(MPColors.textPrimary)

                    // Показать путь для поиска
                    if isSearching, let parent = category.parent {
                        Text(parent.name)
                            .font(.system(size: 11))
                            .foregroundColor(MPColors.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(.leading, isChild ? MPSpacing.md + 36 + MPSpacing.sm : MPSpacing.md)
            .padding(.trailing, MPSpacing.md)
            .padding(.vertical, isChild ? MPSpacing.xs : MPSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Сбросить

    private var resetButton: some View {
        Button {
            withAnimation { selectedCategoryIds.removeAll() }
        } label: {
            Text("Сбросить фильтр")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.accentCoral)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MPSpacing.sm)
                .background(MPColors.cardBackground)
                .cornerRadius(MPCornerRadius.md)
        }
        .buttonStyle(.plain)
    }
}
