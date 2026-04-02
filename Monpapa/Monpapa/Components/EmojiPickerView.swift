// MonPapa iOS — Компонент выбора Emoji для категорий

import SwiftUI

struct EmojiPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedEmoji: String
    
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    
    // MARK: - Данные
    
    private static let categories: [(name: String, icon: String, emojis: [String])] = [
        ("Еда и напитки", "🍽️", [
            "🛒", "🍕", "🍔", "🌭", "🍟", "🥗", "🍣", "🍱",
            "🥩", "🍗", "🥚", "🧀", "🍞", "🥐", "🍰", "🎂",
            "🍩", "🍪", "🍫", "☕", "🍺", "🍷", "🥤", "🧃",
            "🍎", "🍌", "🥑", "🥕", "🌽", "🍓", "🛵"
        ]),
        ("Транспорт", "🚗", [
            "🚗", "🚕", "🚌", "🚇", "🚆", "✈️", "🚢", "🛳️",
            "⛽", "🅿️", "🚲", "🛴", "🏍️", "🚁", "🚀", "🛞"
        ]),
        ("Дом и быт", "🏠", [
            "🏠", "🏡", "🔑", "🛋️", "🛏️", "🚿", "🧹", "🧺",
            "💡", "🔌", "📺", "🖥️", "🧊", "🌡️", "🪑", "🪴"
        ]),
        ("Здоровье", "💊", [
            "💊", "💉", "🩺", "🏥", "🦷", "👓", "🧬", "🩹",
            "🏋️", "🧘", "🤸", "⚽", "🎾", "🏊", "🚴", "🧖"
        ]),
        ("Покупки", "🛍️", [
            "🛍️", "👕", "👖", "👗", "👟", "👜", "🧢", "💍",
            "💄", "🧴", "👠", "🧥", "🧣", "🎒", "⌚", "🕶️"
        ]),
        ("Развлечения", "🎬", [
            "🎬", "🎮", "🎲", "🎪", "🎠", "🎡", "🎢", "🎯",
            "🎭", "🎨", "🎵", "🎸", "📚", "📖", "🎤", "🎧"
        ]),
        ("Финансы", "💰", [
            "💰", "💵", "💳", "🏦", "📊", "📈", "📉", "💹",
            "🪙", "💎", "🏧", "💲", "🧾", "📋", "✅", "📌"
        ]),
        ("Образование", "🎓", [
            "🎓", "📚", "📝", "✏️", "📐", "🔬", "🔭", "💻",
            "🖊️", "📓", "🗂️", "📎", "🗃️", "🧑‍💻", "👨‍🏫", "🏫"
        ]),
        ("Дети", "👶", [
            "👶", "🧒", "🍼", "🧸", "🎈", "🎁", "🎀", "🪆",
            "🏫", "📏", "🖍️", "🎠", "👣", "🐣", "🐶", "🐱"
        ]),
        ("Путешествия", "🌍", [
            "🌍", "✈️", "🏖️", "🏔️", "🗺️", "🧳", "🏨", "⛺",
            "🌅", "🗼", "🏝️", "🎢", "📸", "🛂", "🌴", "⛱️"
        ]),
        ("Связь", "📱", [
            "📱", "💻", "📞", "📧", "📡", "🌐", "📶", "🔗",
            "📬", "📮", "🖨️", "⌨️", "🖱️", "💾", "📲", "🔔"
        ]),
        ("Подарки и праздники", "🎁", [
            "🎁", "🎉", "🎊", "🥂", "🍾", "🎂", "🎈", "🎀",
            "💐", "🌹", "🕯️", "✨", "🥳", "💌", "🎗️", "🏆"
        ]),
        ("Авто", "🚘", [
            "🚘", "🔧", "🛠️", "🏎️", "🚙", "🚐", "🛻", "🚚",
            "🧰", "⛽", "🅿️", "🚦", "🛞", "🪫", "🔋", "🧲"
        ]),
        ("Животные", "🐾", [
            "🐾", "🐶", "🐱", "🐠", "🐦", "🐹", "🐰", "🦜",
            "🐢", "🐍", "🦎", "🐴", "🐄", "🐝", "🦋", "🐛"
        ]),
    ]
    
    // MARK: - Поиск
    
    /// Все emoji в одном списке (для поиска по символу)
    private var filteredCategories: [(name: String, icon: String, emojis: [String])] {
        guard !searchText.isEmpty else { return Self.categories }
        
        let query = searchText.lowercased()
        
        // Фильтруем категории по имени и emoji по совпадению
        return Self.categories.compactMap { category in
            // Если название категории совпадает — возвращаем всю категорию
            if category.name.lowercased().contains(query) {
                return category
            }
            // Иначе фильтруем emoji внутри категории
            let matched = category.emojis.filter { $0.contains(query) }
            if matched.isEmpty { return nil }
            return (category.name, category.icon, matched)
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ZStack {
                MPColors.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: MPSpacing.lg) {
                        // Поиск по категориям
                        searchBar
                        
                        if filteredCategories.isEmpty {
                            emptyState
                        } else {
                            // Секции emoji по категориям
                            ForEach(filteredCategories, id: \.name) { category in
                                emojiSection(category)
                            }
                        }
                    }
                    .padding(.horizontal, MPSpacing.md)
                    .padding(.bottom, MPSpacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
                .dismissKeyboardOnTap()
            }
            .navigationTitle("Иконка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !selectedEmoji.isEmpty {
                        Button {
                            selectedEmoji = ""
                            dismiss()
                        } label: {
                            Text("Убрать")
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(MPColors.accentCoral)
                }
            }
        }
    }
    
    // MARK: - Поиск
    
    private var searchBar: some View {
        HStack(spacing: MPSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(MPColors.textSecondary)
                .font(.system(size: 16))
            
            TextField("Поиск по категориям...", text: $searchText)
                .font(.system(size: 16, design: .rounded))
                .foregroundColor(MPColors.textPrimary)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, MPSpacing.md)
        .padding(.vertical, MPSpacing.sm)
        .background(MPColors.cardBackground)
        .cornerRadius(MPCornerRadius.md)
    }
    
    // MARK: - Секция emoji
    
    private func emojiSection(_ category: (name: String, icon: String, emojis: [String])) -> some View {
        VStack(alignment: .leading, spacing: MPSpacing.sm) {
            // Заголовок секции
            HStack(spacing: MPSpacing.xs) {
                Text(category.icon)
                    .font(.system(size: 16))
                Text(category.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(MPColors.textSecondary)
            }
            .padding(.leading, MPSpacing.xs)
            
            // Grid emoji
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8),
                spacing: 8
            ) {
                ForEach(category.emojis, id: \.self) { emoji in
                    emojiButton(emoji)
                }
            }
        }
    }
    
    // MARK: - Кнопка emoji
    
    private func emojiButton(_ emoji: String) -> some View {
        Button {
            selectedEmoji = emoji
            // Haptic
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            dismiss()
        } label: {
            Text(emoji)
                .font(.system(size: 28))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: MPCornerRadius.sm)
                        .fill(
                            selectedEmoji == emoji
                                ? MPColors.accentCoral.opacity(0.15)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MPCornerRadius.sm)
                        .stroke(
                            selectedEmoji == emoji
                                ? MPColors.accentCoral.opacity(0.4)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Пустой результат
    
    private var emptyState: some View {
        VStack(spacing: MPSpacing.md) {
            Text("😕")
                .font(.system(size: 48))
            Text("Ничего не найдено")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Preview

#Preview {
    EmojiPickerView(selectedEmoji: .constant("🛒"))
}
