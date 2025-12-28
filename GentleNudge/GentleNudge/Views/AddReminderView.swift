import SwiftUI
import SwiftData

struct AddReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var title = ""
    @State private var notes = ""
    @State private var selectedCategory: Category?
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var priority: ReminderPriority = .none
    @State private var recurrence: RecurrenceType = .none

    @State private var isSuggestingCategory = false
    @State private var showingDatePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Constants.Spacing.lg) {
                    // Title Field
                    VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                        Text("Title")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("What do you need to remember?", text: $title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .lineLimit(3)
                            .padding()
                            .background(AppColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Notes Field
                    VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                        Text("Notes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Add details, links, or context...", text: $notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(5...10)
                            .padding()
                            .background(AppColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Category Selection
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        HStack {
                            Text("Category")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            AISuggestButton(
                                title: "AI Suggest",
                                icon: "sparkles",
                                isLoading: isSuggestingCategory
                            ) {
                                suggestCategory()
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Constants.Spacing.xs) {
                                ForEach(categories) { category in
                                    CategoryChipSelectable(
                                        category: category,
                                        isSelected: selectedCategory?.id == category.id
                                    ) {
                                        HapticManager.selection()
                                        withAnimation(Constants.Animation.quick) {
                                            if selectedCategory?.id == category.id {
                                                selectedCategory = nil
                                            } else {
                                                selectedCategory = category
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Due Date
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        Text("Due Date")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(spacing: Constants.Spacing.sm) {
                            Toggle("Set due date", isOn: $hasDueDate.animation())

                            if hasDueDate {
                                HStack(spacing: Constants.Spacing.xs) {
                                    QuickDateButton(title: "Today", date: Date()) {
                                        dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
                                    }
                                    QuickDateButton(title: "Tomorrow", date: Date.tomorrow) {
                                        dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.tomorrow)
                                    }
                                    QuickDateButton(title: "Next Week", date: Date.nextWeek) {
                                        dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.nextWeek)
                                    }
                                }

                                DatePicker(
                                    "Due",
                                    selection: Binding(
                                        get: { dueDate ?? Date() },
                                        set: { dueDate = $0 }
                                    ),
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .datePickerStyle(.graphical)
                            }
                        }
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        Text("Priority")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: Constants.Spacing.xs) {
                            ForEach(ReminderPriority.allCases, id: \.self) { p in
                                PriorityButton(priority: p, isSelected: priority == p) {
                                    HapticManager.selection()
                                    priority = p
                                }
                            }
                        }
                    }

                    // Recurrence (only show if due date is set)
                    if hasDueDate {
                        RecurrencePicker(recurrence: $recurrence)
                    }
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle("New Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addReminder()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addReminder() {
        let reminder = Reminder(
            title: title.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespaces),
            dueDate: hasDueDate ? dueDate : nil,
            priority: priority,
            category: selectedCategory,
            recurrence: hasDueDate ? recurrence : .none
        )

        modelContext.insert(reminder)
        HapticManager.notification(.success)
        dismiss()
    }

    private func suggestCategory() {
        guard !title.isEmpty else { return }

        isSuggestingCategory = true
        Task {
            do {
                let categoryNames = categories.map { $0.name }
                let suggestion = try await ClaudeService.shared.suggestCategory(
                    title: title,
                    notes: notes,
                    existingCategories: categoryNames
                )

                await MainActor.run {
                    if let category = categories.first(where: { $0.name.lowercased() == suggestion.lowercased() }) {
                        withAnimation {
                            selectedCategory = category
                        }
                        HapticManager.notification(.success)
                    }
                    isSuggestingCategory = false
                }
            } catch {
                await MainActor.run {
                    isSuggestingCategory = false
                }
            }
        }
    }
}

struct QuickDateButton: View {
    let title: String
    let date: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.tertiaryBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PriorityButton: View {
    let priority: ReminderPriority
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = priority.icon {
                    Image(systemName: icon)
                }
                Text(priority.label)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : priority == .none ? .primary : priority.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? (priority == .none ? Color.gray : priority.color) : AppColors.secondaryBackground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AddReminderView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
