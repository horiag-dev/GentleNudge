import SwiftUI
import SwiftData

struct ReminderDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @Bindable var reminder: Reminder

    @State private var isEnhancing = false
    @State private var isSuggestingCategory = false
    @State private var showDeleteConfirmation = false
    @State private var hasDueDate: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                // Completion Status
                HStack {
                    Button {
                        withAnimation(Constants.Animation.spring) {
                            HapticManager.notification(reminder.isCompleted ? .warning : .success)
                            if reminder.isCompleted {
                                reminder.markIncomplete()
                            } else {
                                completeReminder()
                            }
                        }
                    } label: {
                        HStack(spacing: Constants.Spacing.sm) {
                            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title)
                                .foregroundStyle(reminder.isCompleted ? .green : .secondary)
                            Text(reminder.isCompleted ? "Completed" : "Mark Complete")
                                .font(.headline)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(reminder.isCompleted ? Color.green.opacity(0.1) : AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }
                    .buttonStyle(.plain)
                }

                // Title
                VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                    Text("Title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Title", text: $reminder.title, axis: .vertical)
                        .font(.title3)
                        .lineLimit(3)
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                }

                // Notes
                VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                    Text("Notes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Add notes...", text: $reminder.notes, axis: .vertical)
                        .lineLimit(5...10)
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                }

                // AI Enhancement
                VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                    HStack {
                        Text("AI Context")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        AIEnhanceButton(isLoading: isEnhancing) {
                            enhanceWithAI()
                        }
                    }

                    if let aiDescription = reminder.aiEnhancedDescription, !aiDescription.isEmpty {
                        HStack(alignment: .top, spacing: Constants.Spacing.sm) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.purple)
                            Text(aiDescription)
                                .font(.body)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [.purple.opacity(0.1), .blue.opacity(0.1)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }
                }

                // Category
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
                                    isSelected: reminder.category?.id == category.id
                                ) {
                                    HapticManager.selection()
                                    withAnimation(Constants.Animation.quick) {
                                        if reminder.category?.id == category.id {
                                            reminder.category = nil
                                        } else {
                                            reminder.category = category
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
                            .onChange(of: hasDueDate) { _, newValue in
                                if !newValue {
                                    reminder.dueDate = nil
                                } else if reminder.dueDate == nil {
                                    reminder.dueDate = Date()
                                }
                            }

                        if hasDueDate {
                            DatePicker(
                                "Due",
                                selection: Binding(
                                    get: { reminder.dueDate ?? Date() },
                                    set: { reminder.dueDate = $0 }
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
                            PriorityButton(priority: p, isSelected: reminder.priority == p) {
                                HapticManager.selection()
                                reminder.priority = p
                            }
                        }
                    }
                }

                // Recurrence (only show if due date is set)
                if hasDueDate {
                    RecurrencePicker(recurrence: $reminder.recurrence)
                }

                // Metadata
                VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                    Text("Created: \(reminder.createdAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let completedAt = reminder.completedAt {
                        Text("Completed: \(completedAt.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if reminder.hasBeenSynced {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.icloud")
                            Text("Synced to Apple Reminders")
                        }
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))

                // Delete Button
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Reminder", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                }
            }
            .padding()
        }
        .background(AppColors.background)
        .navigationTitle("Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasDueDate = reminder.dueDate != nil
        }
        .confirmationDialog("Delete Reminder", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                modelContext.delete(reminder)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete this reminder? This action cannot be undone.")
        }
    }

    private func enhanceWithAI() {
        guard !reminder.title.isEmpty else { return }

        isEnhancing = true
        Task {
            do {
                let enhanced = try await ClaudeService.shared.enhanceReminder(
                    title: reminder.title,
                    notes: reminder.notes
                )

                await MainActor.run {
                    withAnimation {
                        reminder.aiEnhancedDescription = enhanced
                    }
                    HapticManager.notification(.success)
                    isEnhancing = false
                }
            } catch {
                await MainActor.run {
                    isEnhancing = false
                    HapticManager.notification(.error)
                }
            }
        }
    }

    private func suggestCategory() {
        guard !reminder.title.isEmpty else { return }

        isSuggestingCategory = true
        Task {
            do {
                let categoryNames = categories.map { $0.name }
                let suggestion = try await ClaudeService.shared.suggestCategory(
                    title: reminder.title,
                    notes: reminder.notes,
                    existingCategories: categoryNames
                )

                await MainActor.run {
                    if let category = categories.first(where: { $0.name.lowercased() == suggestion.lowercased() }) {
                        withAnimation {
                            reminder.category = category
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

    private func completeReminder() {
        // If recurring, create next occurrence before marking complete
        if reminder.isRecurring, let nextReminder = reminder.createNextOccurrence() {
            modelContext.insert(nextReminder)
        }
        reminder.markCompleted()
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Reminder.self, Category.self, configurations: config)

    let reminder = Reminder(title: "Watch SwiftUI tutorial", notes: "https://youtube.com/watch?v=abc123", dueDate: Date())
    container.mainContext.insert(reminder)

    return NavigationStack {
        ReminderDetailView(reminder: reminder)
    }
    .modelContainer(container)
}
