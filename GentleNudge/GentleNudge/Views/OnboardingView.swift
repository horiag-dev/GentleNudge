import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var currentPage = 0
    @State private var selectedCategories: Set<String> = []
    @State private var selectedHabits: Set<String> = []
    @State private var selectedTasks: Set<String> = []

    private let totalPages = 5

    // Available categories with descriptions
    private let categoryDescriptions: [(name: String, description: String, icon: String, color: String)] = [
        ("Habits", "Daily routines and habits to build", "heart.circle.fill", "red"),
        ("Today", "Things that need attention today", "sun.max.fill", "yellow"),
        ("House", "Home maintenance and chores", "house.fill", "green"),
        ("Photos", "Photo organization and projects", "photo.fill", "purple"),
        ("Finance", "Bills, budgets, and money tasks", "dollarsign.circle.fill", "teal"),
        ("To Read", "Books, articles, and reading list", "book.fill", "blue"),
        ("Startup", "Business and side project ideas", "lightbulb.fill", "orange"),
        ("Explore", "Places to visit and things to try", "safari.fill", "indigo"),
        ("GenAI", "AI projects and experiments", "sparkles", "pink"),
        ("Misc", "Everything else", "tray.fill", "mint"),
    ]

    // Suggested habits for new users
    private let suggestedHabits: [(title: String, notes: String, icon: String)] = [
        ("Exercise", "30 minutes of movement", "figure.run"),
        ("Read", "At least 20 pages", "book.fill"),
        ("Meditate", "10 minute session", "brain.head.profile"),
        ("Journal", "Reflect on the day", "pencil.and.list.clipboard"),
        ("Drink water", "8 glasses throughout the day", "drop.fill"),
        ("Sleep 8 hours", "Consistent bedtime", "moon.fill"),
    ]

    // Suggested starter tasks
    private let suggestedTasks: [(title: String, category: String, icon: String)] = [
        ("Organize photo library", "Photos", "photo.fill"),
        ("Review subscriptions", "Finance", "creditcard.fill"),
        ("Plan weekend activity", "Explore", "map.fill"),
        ("Backup important files", "Misc", "externaldrive.fill"),
        ("Update resume", "Misc", "doc.text.fill"),
        ("Try a new recipe", "Explore", "fork.knife"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                welcomePage
                    .tag(0)

                categoriesPage
                    .tag(1)

                habitsPage
                    .tag(2)

                tasksPage
                    .tag(3)

                setupPage
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentPage)

            // Navigation
            VStack(spacing: Constants.Spacing.md) {
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                // Buttons
                HStack(spacing: Constants.Spacing.md) {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation {
                                currentPage -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if currentPage < totalPages - 1 {
                        Button("Next") {
                            withAnimation {
                                currentPage += 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Get Started") {
                            finishOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(AppColors.background)
        }
        .background(AppColors.background)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.xl) {
                Spacer(minLength: 40)

                // App icon
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: Constants.Spacing.sm) {
                    Text("Welcome to Gentle Nudge")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Your personal reminder companion")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: Constants.Spacing.lg) {
                    FeatureRow(
                        icon: "tray.full.fill",
                        title: "Track Everything",
                        description: "Keep track of tasks, ideas, and things you want to remember - without the pressure of due dates"
                    )

                    FeatureRow(
                        icon: "heart.circle.fill",
                        title: "Build Habits",
                        description: "Daily habits with streak tracking to help you stay consistent"
                    )

                    FeatureRow(
                        icon: "sparkles",
                        title: "AI-Powered",
                        description: "Claude AI helps categorize and enhance your reminders automatically"
                    )

                    FeatureRow(
                        icon: "icloud.fill",
                        title: "Synced Everywhere",
                        description: "Your reminders sync across all your Apple devices via iCloud"
                    )
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding()
        }
    }

    private var categoriesPage: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                Spacer(minLength: 20)

                VStack(spacing: Constants.Spacing.sm) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue)

                    Text("Choose Your Categories")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Select the categories that fit your life. You can always add or remove them later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: Constants.Spacing.sm) {
                    ForEach(categoryDescriptions, id: \.name) { category in
                        CategorySelectableRow(
                            name: category.name,
                            description: category.description,
                            icon: category.icon,
                            colorName: category.color,
                            isSelected: selectedCategories.contains(category.name)
                        ) {
                            if selectedCategories.contains(category.name) {
                                selectedCategories.remove(category.name)
                            } else {
                                selectedCategories.insert(category.name)
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Text("Tip: Start with a few categories. Less is more!")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 40)
            }
            .padding()
        }
        .onAppear {
            // Pre-select some common categories
            if selectedCategories.isEmpty {
                selectedCategories = ["Habits", "Today", "House", "Misc"]
            }
        }
    }

    private var habitsPage: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                Spacer(minLength: 20)

                VStack(spacing: Constants.Spacing.sm) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.red)

                    Text("Start with Habits")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Select habits you'd like to build. These will appear in your daily view.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: Constants.Spacing.sm) {
                    ForEach(suggestedHabits, id: \.title) { habit in
                        SelectableRow(
                            icon: habit.icon,
                            title: habit.title,
                            subtitle: habit.notes,
                            isSelected: selectedHabits.contains(habit.title)
                        ) {
                            if selectedHabits.contains(habit.title) {
                                selectedHabits.remove(habit.title)
                            } else {
                                selectedHabits.insert(habit.title)
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Text("You can always add more habits later")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 40)
            }
            .padding()
        }
    }

    private var tasksPage: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                Spacer(minLength: 20)

                VStack(spacing: Constants.Spacing.sm) {
                    Image(systemName: "checklist")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue)

                    Text("Add Some Tasks")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Here are some common things people like to track. Select any that apply to you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: Constants.Spacing.sm) {
                    ForEach(suggestedTasks, id: \.title) { task in
                        SelectableRow(
                            icon: task.icon,
                            title: task.title,
                            subtitle: task.category,
                            isSelected: selectedTasks.contains(task.title)
                        ) {
                            if selectedTasks.contains(task.title) {
                                selectedTasks.remove(task.title)
                            } else {
                                selectedTasks.insert(task.title)
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Text("Don't worry - you can add your own tasks anytime")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 40)
            }
            .padding()
        }
    }

    private var setupPage: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                Spacer(minLength: 20)

                VStack(spacing: Constants.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.green)

                    Text("You're All Set!")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Here's what we'll create for you:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: Constants.Spacing.md) {
                    if !selectedCategories.isEmpty {
                        SummarySection(
                            title: "Categories",
                            icon: "folder.fill",
                            color: .blue,
                            items: Array(selectedCategories).sorted()
                        )
                    }

                    if !selectedHabits.isEmpty {
                        SummarySection(
                            title: "Habits",
                            icon: "heart.circle.fill",
                            color: .red,
                            items: Array(selectedHabits)
                        )
                    }

                    if !selectedTasks.isEmpty {
                        SummarySection(
                            title: "Tasks",
                            icon: "checklist",
                            color: .green,
                            items: Array(selectedTasks)
                        )
                    }

                    if selectedCategories.isEmpty && selectedHabits.isEmpty && selectedTasks.isEmpty {
                        Text("No items selected - that's okay! You can customize everything later in Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(AppColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }
                }
                .padding(.horizontal)

                Divider()
                    .padding(.vertical)

                VStack(alignment: .leading, spacing: Constants.Spacing.md) {
                    Text("Tips to get started:")
                        .font(.headline)

                    TipRow(
                        icon: "bell.badge.fill",
                        text: "Enable morning notifications in Settings to get a daily summary"
                    )

                    TipRow(
                        icon: "sparkles",
                        text: "Add your Claude API key in Settings to unlock AI features"
                    )

                    TipRow(
                        icon: "plus.circle.fill",
                        text: "Tap the + button anytime to add new reminders"
                    )

                    TipRow(
                        icon: "hand.tap.fill",
                        text: "Tap a habit to mark it complete for today"
                    )
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func finishOnboarding() {
        // Note: We no longer delete categories here because with CloudKit sync,
        // deleted categories will sync back from other devices.
        // Instead, users can manually delete unwanted categories later.
        // The selected categories are used to determine which habits/tasks to create.

        // Create selected habits (only if Habits category was selected)
        if selectedCategories.contains("Habits"),
           let habitsCategory = categories.first(where: { $0.name == "Habits" }) {
            for habitTitle in selectedHabits {
                if let habit = suggestedHabits.first(where: { $0.title == habitTitle }) {
                    let reminder = Reminder(
                        title: habit.title,
                        notes: habit.notes,
                        dueDate: nil,
                        priority: .normal,
                        category: habitsCategory,
                        recurrence: .daily
                    )
                    modelContext.insert(reminder)
                }
            }
        }

        // Create selected tasks (only if their category was selected)
        for taskTitle in selectedTasks {
            if let task = suggestedTasks.first(where: { $0.title == taskTitle }),
               selectedCategories.contains(task.category),
               let category = categories.first(where: { $0.name == task.category }) {
                let reminder = Reminder(
                    title: task.title,
                    notes: "",
                    dueDate: nil,
                    priority: .normal,
                    category: category
                )
                modelContext.insert(reminder)
            }
        }

        try? modelContext.save()

        // Mark onboarding as complete
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        HapticManager.notification(.success)
        dismiss()
    }
}

// MARK: - Supporting Views

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SelectableRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Constants.Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .padding()
            .background(isSelected ? Color.accentColor : AppColors.secondaryBackground)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
        }
        .buttonStyle(.plain)
    }
}

private struct SummarySection: View {
    let title: String
    let icon: String
    let color: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }

            ForEach(items, id: \.self) { item in
                HStack {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(item)
                        .font(.subheadline)
                }
                .padding(.leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CategorySelectableRow: View {
    let name: String
    let description: String
    let icon: String
    let colorName: String
    let isSelected: Bool
    let action: () -> Void

    private var color: Color {
        switch colorName {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "teal": return .teal
        case "blue": return .blue
        case "orange": return .orange
        case "indigo": return .indigo
        case "pink": return .pink
        case "mint": return .mint
        default: return .gray
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Constants.Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : color)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isSelected ? color : color.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? color : .secondary)
            }
            .padding()
            .background(isSelected ? color.opacity(0.1) : AppColors.secondaryBackground)
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                    .stroke(isSelected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
