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
    @State private var recurrence: RecurrenceType = .none

    @State private var showingDatePicker = false

    // Quick date selection helpers
    private var isDateToday: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    private var isDateTomorrow: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInTomorrow(dueDate)
    }

    private var isDateWeekend: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDate(dueDate, inSameDayAs: Date.nextWeekend)
    }

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

                        // Show clickable links if notes contain URLs
                        if !notes.extractedURLs.isEmpty {
                            VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                                ForEach(notes.extractedURLs, id: \.absoluteString) { url in
                                    Link(destination: url) {
                                        HStack {
                                            Image(systemName: "link")
                                            Text(url.host ?? url.absoluteString)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption)
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(.blue)
                                        .padding(Constants.Spacing.sm)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
                                    }
                                }
                            }
                        }
                    }

                    // Category Selection (required)
                    VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                        HStack(spacing: Constants.Spacing.xs) {
                            Text("Category")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if selectedCategory == nil {
                                Text("(required)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        FlowLayout(spacing: Constants.Spacing.xs) {
                            ForEach(categories) { category in
                                CategoryChipSelectable(
                                    category: category,
                                    isSelected: selectedCategory?.id == category.id
                                ) {
                                    HapticManager.selection()
                                    withAnimation(Constants.Animation.quick) {
                                        selectedCategory = category
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
                            HStack(spacing: Constants.Spacing.xs) {
                                QuickDateButton(title: "Today", date: Date(), isSelected: isDateToday) {
                                    dueDate = Calendar.current.startOfDay(for: Date())
                                }
                                QuickDateButton(title: "Tomorrow", date: Date.tomorrow, isSelected: isDateTomorrow) {
                                    dueDate = Calendar.current.startOfDay(for: Date.tomorrow)
                                }
                                QuickDateButton(title: "Weekend", date: Date.nextWeekend, isSelected: isDateWeekend) {
                                    dueDate = Date.nextWeekend
                                }
                                QuickDateButton(title: "Pick date", date: Date(), isSelected: showingDatePicker) {
                                    withAnimation {
                                        showingDatePicker = true
                                        if dueDate == nil {
                                            dueDate = Calendar.current.startOfDay(for: Date())
                                        }
                                    }
                                }
                            }

                            if dueDate != nil {
                                if showingDatePicker {
                                    DatePicker(
                                        "Due",
                                        selection: Binding(
                                            get: { dueDate ?? Date() },
                                            set: { dueDate = $0 }
                                        ),
                                        displayedComponents: [.date]
                                    )
                                    .datePickerStyle(.graphical)
                                }

                                // Recurrence
                                RecurrencePicker(recurrence: $recurrence)

                                Button {
                                    dueDate = nil
                                    showingDatePicker = false
                                    recurrence = .none
                                } label: {
                                    Text("Clear date")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle("New Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || selectedCategory == nil)
                }
            }
        }
    }

    private func addReminder() {
        let reminder = Reminder(
            title: title.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespaces),
            dueDate: dueDate,
            category: selectedCategory,
            recurrence: dueDate != nil ? recurrence : .none
        )

        modelContext.insert(reminder)
        HapticManager.notification(.success)
        dismiss()
    }

}

struct QuickDateButton: View {
    let title: String
    let date: Date
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : AppColors.tertiaryBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AddReminderView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
