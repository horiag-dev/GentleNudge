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
        case recurring = "Recurring"
        case completed = "Completed"
        case all = "All"
    }

    private var filteredReminders: [Reminder] {
        var result = reminders

        // Apply status filter
        switch selectedFilter {
        case .active:
            result = result.filter { !$0.isCompleted }
        case .recurring:
            result = result.filter { $0.isRecurring && !$0.isCompleted }
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

        // Sort based on filter type
        switch selectedFilter {
        case .completed:
            return result.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        case .recurring:
            // Sort by recurrence type (daily first), then by due date
            return result.sorted { r1, r2 in
                if r1.recurrence.rawValue != r2.recurrence.rawValue {
                    return r1.recurrence.rawValue < r2.recurrence.rawValue
                }
                return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
            }
        default:
            return result.sorted { ($0.createdAt) > ($1.createdAt) }
        }
    }

    var body: some View {
        NavigationStack {
            let currentFiltered = filteredReminders

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

                    // Different views based on filter
                    switch selectedFilter {
                    case .completed:
                        // Flat list sorted by completion date (most recent first)
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            HStack(spacing: Constants.Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Recently Completed")
                                    .font(.headline)
                                Spacer()
                                Text("\(currentFiltered.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Constants.Spacing.xs)

                            VStack(spacing: Constants.Spacing.xs) {
                                ForEach(currentFiltered) { reminder in
                                    CompletedReminderRow(reminder: reminder)
                                }
                            }
                        }
                        .padding(.horizontal)

                    case .recurring:
                        // Simple list of recurring items grouped by frequency
                        RecurringRemindersSection(reminders: currentFiltered)
                            .padding(.horizontal)

                    default:
                        // Reminders by Category
                        ForEach(categories) { category in
                            let categoryReminders = currentFiltered.filter { $0.category?.id == category.id }
                            if !categoryReminders.isEmpty {
                                CategorySection(category: category, reminders: categoryReminders)
                            }
                        }

                        // Uncategorized
                        let uncategorized = currentFiltered.filter { $0.category == nil }
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
                    }

                    if currentFiltered.isEmpty {
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

// Row for completed reminders showing completion time
struct CompletedReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder

    var body: some View {
        NavigationLink {
            ReminderDetailView(reminder: reminder)
        } label: {
            HStack(spacing: Constants.Spacing.sm) {
                // Undo button
                Button {
                    withAnimation {
                        reminder.uncomplete(in: modelContext)
                    }
                    HapticManager.impact(.light)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: Constants.Spacing.xs) {
                        // Category chip
                        if let category = reminder.category {
                            HStack(spacing: 2) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 10))
                                Text(category.name)
                                    .font(.caption2)
                            }
                            .foregroundStyle(category.color)
                        }

                        // Completion time
                        if let completedAt = reminder.completedAt {
                            Text(formatCompletionTime(completedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                // Completed checkmark
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .padding(.vertical, Constants.Spacing.xs)
            .padding(.horizontal, Constants.Spacing.sm)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
        }
        .buttonStyle(.plain)
    }

    private func formatCompletionTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today at \(date.formatted(date: .omitted, time: .shortened))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday at \(date.formatted(date: .omitted, time: .shortened))"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        } else {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

// MARK: - Recurring Reminders Section

struct RecurringRemindersSection: View {
    let reminders: [Reminder]

    private struct RecurrenceGroupData: Identifiable {
        let id: String
        let title: String
        let icon: String
        let color: Color
        let reminders: [Reminder]
    }

    private var groupedByRecurrence: [RecurrenceGroupData] {
        // Single pass to group by recurrence type
        var grouped: [RecurrenceType: [Reminder]] = [:]
        for reminder in reminders {
            grouped[reminder.recurrence, default: []].append(reminder)
        }

        let groupDefs: [(type: RecurrenceType, title: String, icon: String, color: Color)] = [
            (.daily, "Daily", "sun.max.fill", .yellow),
            (.weekly, "Weekly", "calendar.circle", .blue),
            (.biweekly, "Every 2 Weeks", "calendar.badge.clock", .purple),
            (.monthly, "Monthly", "calendar", .green),
        ]

        return groupDefs.compactMap { def in
            guard let items = grouped[def.type], !items.isEmpty else { return nil }
            return RecurrenceGroupData(id: def.title, title: def.title, icon: def.icon, color: def.color, reminders: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.md) {
            // Header
            HStack(spacing: Constants.Spacing.xs) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                    .foregroundStyle(.orange)
                Text("Recurring Tasks")
                    .font(.headline)
                Spacer()
                Text("\(reminders.count) total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(groupedByRecurrence) { group in
                RecurrenceGroup(
                    title: group.title,
                    icon: group.icon,
                    color: group.color,
                    reminders: group.reminders
                )
            }
        }
    }
}

struct RecurrenceGroup: View {
    let title: String
    let icon: String
    let color: Color
    let reminders: [Reminder]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("(\(reminders.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(color)

            ForEach(reminders) { reminder in
                RecurringReminderRow(reminder: reminder)
            }
        }
        .padding(Constants.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.sm)
                .fill(color.opacity(0.08))
        )
    }
}

struct RecurringReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
            // Completion toggle
            Button {
                withAnimation {
                    reminder.complete(in: modelContext)
                }
                HapticManager.impact(.medium)
            } label: {
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: Constants.Spacing.xs) {
                    // Category
                    if let category = reminder.category {
                        HStack(spacing: 2) {
                            Image(systemName: category.icon)
                                .font(.system(size: 10))
                            Text(category.name)
                                .font(.caption2)
                        }
                        .foregroundStyle(category.color)
                    }

                    // Next due
                    if let dueText = reminder.daysUntilDueText {
                        Text(dueText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    AllRemindersView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
