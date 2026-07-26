import SwiftUI
import SwiftData

struct ReminderDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @Bindable var reminder: Reminder

    /// Local edit buffers: the text fields bind here instead of straight to the
    /// `@Model`, so a keystroke re-renders only this view instead of
    /// invalidating every `@Query` in the app (and churning autosave/CloudKit).
    /// Committed back to the model on field blur and on disappear — see
    /// `commitTitle()` / `commitNotes()`.
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    /// Baselines = the last value each draft was loaded FROM the model with (or
    /// committed back to it). A field is **dirty** — i.e. the user actually typed
    /// in it — exactly when its draft differs from its baseline, so programmatic
    /// loads/reloads never count as user edits. Only dirty fields are committed;
    /// a clean field tracks external model changes (assistant rename, CloudKit
    /// merge) instead of clobbering them with a stale draft on close.
    @State private var titleBaseline = ""
    @State private var notesBaseline = ""
    @FocusState private var focusedField: EditField?

    private var titleIsDirty: Bool { titleDraft != titleBaseline }
    private var notesIsDirty: Bool { notesDraft != notesBaseline }

    private enum EditField {
        case title
        case notes
    }

    @State private var isEnhancing = false
    @State private var showDeleteConfirmation = false
    @State private var showingDatePicker: Bool = false
    @State private var showingAIError = false
    @State private var aiErrorMessage = ""

    private var isDateToday: Bool {
        guard let dueDate = reminder.dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    private var isDateTomorrow: Bool {
        guard let dueDate = reminder.dueDate else { return false }
        return Calendar.current.isDateInTomorrow(dueDate)
    }

    private var isDateWeekend: Bool {
        guard let dueDate = reminder.dueDate else { return false }
        return Calendar.current.isDate(dueDate, inSameDayAs: Date.nextWeekend)
    }

    var body: some View {
        // The reminder can be deleted out from under this open sheet (assistant
        // tool call, or another device via a CloudKit merge). Reading properties
        // of an invalidated @Model crashes, so every body read is guarded behind
        // this check — render nothing and dismiss instead.
        if reminder.isDeleted {
            Color.clear
                .onAppear { dismiss() }
        } else {
            detailContent
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(spacing: Constants.Spacing.lg) {
                // Completion Status
                HStack {
                    Button {
                        withAnimation(Constants.Animation.spring) {
                            HapticManager.notification(reminder.isCompleted ? .warning : .success)
                            if reminder.isCompleted {
                                reminder.uncomplete(in: modelContext)
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

                // In-progress sub-state — only meaningful while the reminder is
                // active (habits track per-day completion instead).
                if !reminder.isCompleted && !reminder.isHabit {
                    Button {
                        withAnimation(Constants.Animation.spring) {
                            HapticManager.impact(.light)
                            reminder.setInProgress(!reminder.isInProgress)
                        }
                    } label: {
                        HStack(spacing: Constants.Spacing.sm) {
                            // Same glyph as every other in-progress surface
                            // (rows, Mac menu): half-filled circle, indigo when
                            // active — not the one-off play.circle.
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.title)
                                .foregroundStyle(reminder.isInProgress ? Color.indigo : Color.secondary)
                            Text(reminder.isInProgress ? "In Progress" : "Mark In Progress")
                                .font(.headline)
                            Spacer()
                            if reminder.isInProgress {
                                Text("Tap to mark not started")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(reminder.isInProgress ? Color.indigo.opacity(0.1) : AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                    }
                    .buttonStyle(.plain)
                }

                // Title
                VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                    Text("Title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .focused($focusedField, equals: .title)
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

                    TextField("Add notes...", text: $notesDraft, axis: .vertical)
                        .focused($focusedField, equals: .notes)
                        .lineLimit(5...10)
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))

                    // Show clickable links if notes contain URLs (read from the
                    // draft so links keep appearing live while typing).
                    if !notesDraft.extractedURLs.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                            ForEach(notesDraft.extractedURLs, id: \.absoluteString) { url in
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

                // Polish (fix typos, extract link info)
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
                            .disabled(isEnhancing)

                            Spacer()

                            Text("Fix typos & clarify")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        // Show link info if extracted
                        if let linkInfo = reminder.aiEnhancedDescription, !linkInfo.isEmpty {
                            HStack(alignment: .top, spacing: Constants.Spacing.sm) {
                                Image(systemName: "link.circle.fill")
                                    .foregroundStyle(.blue)
                                Text(linkInfo)
                                    .font(.subheadline)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        }
                    }
                }

                // Category (required)
                VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                    HStack(spacing: Constants.Spacing.xs) {
                        Text("Category")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if reminder.category == nil {
                            Text("(required)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    FlowLayout(spacing: Constants.Spacing.xs) {
                        ForEach(categories) { category in
                            CategoryChipSelectable(
                                category: category,
                                isSelected: reminder.category?.id == category.id
                            ) {
                                HapticManager.selection()
                                withAnimation(Constants.Animation.quick) {
                                    reminder.category = category
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
                                setDueDate(Calendar.current.startOfDay(for: Date()))
                            }
                            QuickDateButton(title: "Tomorrow", date: Date.tomorrow, isSelected: isDateTomorrow) {
                                setDueDate(Calendar.current.startOfDay(for: Date.tomorrow))
                            }
                            QuickDateButton(title: "Weekend", date: Date.nextWeekend, isSelected: isDateWeekend) {
                                setDueDate(Date.nextWeekend)
                            }
                            QuickDateButton(title: "Pick date", date: Date(), isSelected: showingDatePicker) {
                                withAnimation {
                                    showingDatePicker = true
                                    if reminder.dueDate == nil {
                                        setDueDate(Calendar.current.startOfDay(for: Date()))
                                    }
                                }
                            }
                        }

                        if reminder.dueDate != nil {
                            if showingDatePicker {
                                DatePicker(
                                    "Due",
                                    selection: Binding(
                                        get: { reminder.dueDate ?? Date() },
                                        set: { setDueDate($0) }
                                    ),
                                    displayedComponents: [.date]
                                )
                                .datePickerStyle(.graphical)
                            }

                            // Recurrence
                            RecurrencePicker(recurrence: $reminder.recurrence)

                            // Show detailed recurrence description
                            if let detailed = reminder.detailedRecurrence {
                                HStack(spacing: Constants.Spacing.xs) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.purple)
                                    Text(detailed)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, Constants.Spacing.sm)
                            }

                            Button {
                                setDueDate(nil)
                                reminder.recurrence = .none
                                showingDatePicker = false
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            titleDraft = reminder.title
            titleBaseline = reminder.title
            notesDraft = reminder.notes
            notesBaseline = reminder.notes
            showingDatePicker = reminder.dueDate != nil && !isDateToday && !isDateTomorrow && !isDateWeekend
        }
        // Commit point: leaving a field writes its draft back to the model.
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue == .title { commitTitle() }
            if oldValue == .notes { commitNotes() }
        }
        // The model changed underneath us (assistant rename, CloudKit merge).
        // If the user hasn't touched the field, refresh the draft so the editor
        // shows the new value — and so a later blur/disappear commit can't write
        // the stale draft back over the external edit. A dirty field keeps the
        // user's in-flight edit (their typing wins, committed as before).
        .onChange(of: reminder.title) { _, newValue in
            if !titleIsDirty {
                titleDraft = newValue
                titleBaseline = newValue
            }
        }
        .onChange(of: reminder.notes) { _, newValue in
            if !notesIsDirty {
                notesDraft = newValue
                notesBaseline = newValue
            }
        }
        // Safety net: if the view is dismissed while a field still has focus
        // (no blur fired), commit here so no typed edit is ever lost.
        .onDisappear {
            commitTitle()
            commitNotes()
        }
        .confirmationDialog("Delete Reminder", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                modelContext.delete(reminder)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete this reminder? This action cannot be undone.")
        }
        .alert("Polish Failed", isPresented: $showingAIError) {
            Button("OK") {}
        } message: {
            Text(aiErrorMessage)
        }
    }

    /// Writes the title draft back to the model only when the USER edited it
    /// (draft differs from its baseline), then marks the field clean. An
    /// untouched visit never dirties the store — and never reverts an external
    /// edit (assistant rename, CloudKit merge) with a stale draft.
    private func commitTitle() {
        guard titleIsDirty, !reminder.isDeleted else { return }
        if reminder.title != titleDraft {
            reminder.title = titleDraft
        }
        titleBaseline = titleDraft
    }

    /// Same commit-only-when-dirty rule for notes.
    private func commitNotes() {
        guard notesIsDirty, !reminder.isDeleted else { return }
        if reminder.notes != notesDraft {
            reminder.notes = notesDraft
        }
        notesBaseline = notesDraft
    }

    private func polishWithAI() {
        // Polish reads the model, so flush any in-flight (unblurred) edits first.
        commitTitle()
        commitNotes()
        guard !reminder.title.isEmpty else { return }

        isEnhancing = true
        Task {
            do {
                let polished = try await ClaudeService.shared.polishReminder(
                    title: reminder.title,
                    notes: reminder.notes
                )

                await MainActor.run {
                    withAnimation {
                        // Update title if it changed (typos fixed) — keep the
                        // local draft (and its clean baseline) in sync so a later
                        // blur/disappear commit can't overwrite the polished
                        // title with stale text.
                        if polished.title != reminder.title {
                            reminder.title = polished.title
                            titleDraft = polished.title
                            titleBaseline = polished.title
                        }
                        // Store link info if present
                        if let linkInfo = polished.linkInfo {
                            reminder.aiEnhancedDescription = linkInfo
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

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }

    /// All UI due-date edits go through here: picking a new date defines a NEW
    /// schedule anchored to that date's own day-of-month, so any stored month
    /// anchor from the old schedule must be dropped. `monthAnchorDay` trusts
    /// the stored anchor when the due date sits at a short month's end, which
    /// would otherwise resurrect e.g. "the 31st" after the user deliberately
    /// moved a month-end date (Apr 30 → next occurrence May 31, not May 30).
    private func setDueDate(_ date: Date?) {
        reminder.dueDate = date
        reminder.recurrenceAnchorDay = nil
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
