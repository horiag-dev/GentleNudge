import SwiftUI
import SwiftData

struct AllRemindersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var reminders: [Reminder]

    @State private var selectedFilter: ReminderFilter = .active
    @State private var searchText = ""

    enum ReminderFilter: String, CaseIterable {
        case active = "Active"
        case completed = "Completed"
        case all = "All"
    }

    private var filteredReminders: [Reminder] {
        var result = reminders

        // Apply status filter
        switch selectedFilter {
        case .active:
            result = result.filter { !$0.isCompleted }
        case .completed:
            result = result.filter { $0.isCompleted }
        case .all:
            break
        }

        // Apply search
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.notes.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result.sorted { ($0.createdAt) > ($1.createdAt) }
    }

    private func reminders(for category: Category?) -> [Reminder] {
        if let category {
            return filteredReminders.filter { $0.category?.id == category.id }
        } else {
            return filteredReminders.filter { $0.category == nil }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Constants.Spacing.lg) {
                    // Filter Picker
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(ReminderFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // Reminders by Category
                    ForEach(categories) { category in
                        let categoryReminders = reminders(for: category)
                        if !categoryReminders.isEmpty {
                            CategorySection(category: category, reminders: categoryReminders)
                        }
                    }

                    // Uncategorized
                    let uncategorized = reminders(for: nil)
                    if !uncategorized.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            HStack(spacing: Constants.Spacing.xs) {
                                Image(systemName: "questionmark.folder.fill")
                                    .foregroundStyle(.gray)
                                Text("Uncategorized")
                                    .font(.headline)
                                Spacer()
                                Text("\(uncategorized.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Constants.Spacing.xs)

                            VStack(spacing: Constants.Spacing.xs) {
                                ForEach(uncategorized) { reminder in
                                    ReminderRow(reminder: reminder)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if filteredReminders.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No Reminders" : "No Results",
                            systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "Add your first reminder to get started" : "Try a different search term")
                        )
                        .padding(.top, Constants.Spacing.xl)
                    }
                }
                .padding(.vertical)
            }
            .background(AppColors.background)
            .navigationTitle("All Reminders")
            .searchable(text: $searchText, prompt: "Search reminders")
        }
    }
}

struct CategorySection: View {
    let category: Category
    let reminders: [Reminder]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            HStack(spacing: Constants.Spacing.xs) {
                Image(systemName: category.icon)
                    .foregroundStyle(category.color)
                Text(category.name)
                    .font(.headline)
                Spacer()
                Text("\(reminders.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Constants.Spacing.xs)

            VStack(spacing: Constants.Spacing.xs) {
                ForEach(reminders) { reminder in
                    ReminderRow(reminder: reminder)
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    AllRemindersView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
