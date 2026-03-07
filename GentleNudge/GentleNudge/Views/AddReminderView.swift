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

    @State private var isEnhancing = false
    @State private var aiContext = ""
    @State private var showingDatePicker = false
    @State private var showingAIError = false
    @State private var aiErrorMessage = ""

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

                    // Polish Button (fix typos, extract link info)
                    if Constants.isAPIKeyConfigured {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            HStack {
                                Button {
                                    polishWithAI()
                                } label: {
                                    HStack(spacing: Constants.Spacing.xs) {
                                        if isEnhancing {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "wand.and.stars")
                                        }
                                        Text("Polish")
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, Constants.Spacing.sm)
                                    .padding(.vertical, Constants.Spacing.xs)
                                    .background(Color.purple.opacity(0.15))
                                    .foregroundStyle(.purple)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isEnhancing)

                                Spacer()

                                Text("Fix typos & extract link info")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            // Show link info if extracted
                            if !aiContext.isEmpty {
                                HStack(alignment: .top, spacing: Constants.Spacing.sm) {
                                    Image(systemName: "link.circle.fill")
                                        .foregroundStyle(.blue)
                                    Text(aiContext)
                                        .font(.subheadline)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.blue.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
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
            .alert("Polish Failed", isPresented: $showingAIError) {
                Button("OK") {}
            } message: {
                Text(aiErrorMessage)
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

        if !aiContext.isEmpty {
            reminder.aiEnhancedDescription = aiContext
        }

        modelContext.insert(reminder)
        HapticManager.notification(.success)
        dismiss()
    }

    private func polishWithAI() {
        guard !title.isEmpty else { return }

        isEnhancing = true
        Task {
            do {
                let polished = try await ClaudeService.shared.polishReminder(
                    title: title,
                    notes: notes
                )

                await MainActor.run {
                    withAnimation {
                        // Update title if changed (typos fixed)
                        if polished.title != title {
                            title = polished.title
                        }

                        // Store link info if present
                        if let linkInfo = polished.linkInfo {
                            aiContext = linkInfo
                        }
                    }
                    HapticManager.notification(.success)
                    isEnhancing = false
                }
            } catch {
                await MainActor.run {
                    isEnhancing = false
                    aiErrorMessage = error.localizedDescription
                    showingAIError = true
                    HapticManager.notification(.error)
                }
            }
        }
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
