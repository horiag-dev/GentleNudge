import SwiftUI
import SwiftData

struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var reminders: [Reminder]

    @State private var showingAddCategory = false
    @State private var editingCategory: Category?

    private func reminderCount(for category: Category) -> Int {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Constants.Spacing.sm) {
                    ForEach(categories) { category in
                        CategoryCard(
                            category: category,
                            reminderCount: reminderCount(for: category)
                        ) {
                            editingCategory = category
                        }
                    }
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle("Categories")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddCategory = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingAddCategory) {
                EditCategoryView(category: nil)
            }
            .sheet(item: $editingCategory) { category in
                EditCategoryView(category: category)
            }
        }
    }
}

struct CategoryCard: View {
    let category: Category
    let reminderCount: Int
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: Constants.Spacing.md) {
            // Icon
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(category.color)
                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                Text("\(reminderCount) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.lg))
    }
}

struct EditCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let category: Category?

    @State private var name: String = ""
    @State private var selectedIcon: String = "folder.fill"
    @State private var selectedColor: String = "blue"
    @State private var showDeleteConfirmation = false

    private var isNewCategory: Bool { category == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Constants.Spacing.lg) {
                    // Preview
                    VStack {
                        Image(systemName: selectedIcon)
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(colorFromName(selectedColor))
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.lg))

                        Text(name.isEmpty ? "Category Name" : name)
                            .font(.headline)
                    }
                    .padding()

                    // Name Field
                    VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                        Text("Name")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Category name", text: $name)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(AppColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Color Selection
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        Text("Color")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(Category.availableColors, id: \.self) { color in
                                Button {
                                    selectedColor = color
                                    HapticManager.selection()
                                } label: {
                                    Circle()
                                        .fill(colorFromName(color))
                                        .frame(width: 44, height: 44)
                                        .overlay {
                                            if selectedColor == color {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.white)
                                                    .fontWeight(.bold)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Icon Selection
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        Text("Icon")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(Category.availableIcons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                    HapticManager.selection()
                                } label: {
                                    Image(systemName: icon)
                                        .font(.title3)
                                        .foregroundStyle(selectedIcon == icon ? .white : .primary)
                                        .frame(width: 44, height: 44)
                                        .background(selectedIcon == icon ? colorFromName(selectedColor) : AppColors.tertiaryBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Delete Button (for existing categories)
                    if !isNewCategory {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Category", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        }
                    }
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle(isNewCategory ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    selectedIcon = category.icon
                    selectedColor = category.colorName
                }
            }
            .confirmationDialog("Delete Category", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let category {
                        modelContext.delete(category)
                    }
                    dismiss()
                }
            } message: {
                Text("Are you sure? Reminders in this category will become uncategorized.")
            }
        }
    }

    private func save() {
        if let category {
            category.name = name.trimmingCharacters(in: .whitespaces)
            category.icon = selectedIcon
            category.colorName = selectedColor
        } else {
            let newCategory = Category(
                name: name.trimmingCharacters(in: .whitespaces),
                icon: selectedIcon,
                colorName: selectedColor
            )
            modelContext.insert(newCategory)
        }
        HapticManager.notification(.success)
        dismiss()
    }

    private func colorFromName(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "mint": return .mint
        default: return .gray
        }
    }
}

#Preview {
    CategoriesView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
