import SwiftUI
import SwiftData

struct ImportRemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var importState: ImportState = .idle
    @State private var importedReminders: [AppleRemindersService.ImportedReminder] = []
    @State private var progress: Double = 0
    @State private var statusMessage = ""
    @State private var importedCount = 0
    @State private var errorMessage: String?
    @State private var removeDueDates = false
    @State private var enhanceWithAI = true

    enum ImportState {
        case idle
        case requestingAccess
        case fetchingReminders
        case analyzingCategories
        case enhancing
        case importing
        case completed
        case error
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Constants.Spacing.xl) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)

                    if importState == .completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 50, weight: .bold))
                            .foregroundStyle(.white)
                    } else if importState == .error {
                        Image(systemName: "xmark")
                            .font(.system(size: 50, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 50, weight: .medium))
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse, isActive: importState != .idle)
                    }
                }

                // Title & Status
                VStack(spacing: Constants.Spacing.sm) {
                    Text(titleForState)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Progress Bar
                if showProgress {
                    VStack(spacing: Constants.Spacing.xs) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.purple)

                        if importedCount > 0 {
                            Text("\(importedCount) reminders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Constants.Spacing.xl)
                }

                // Error Message
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                // Action Buttons
                VStack(spacing: Constants.Spacing.md) {
                    if importState == .idle {
                        // Options
                        VStack(spacing: Constants.Spacing.sm) {
                            Toggle(isOn: $enhanceWithAI) {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.purple)
                                    Text("Enhance with AI")
                                }
                            }
                            .disabled(!Constants.isAPIKeyConfigured)

                            Toggle(isOn: $removeDueDates) {
                                HStack {
                                    Image(systemName: "calendar.badge.minus")
                                        .foregroundStyle(.orange)
                                    Text("Remove due dates")
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        .padding(.horizontal)

                        Button {
                            startImport()
                        } label: {
                            Label("Import from Apple Reminders", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        }

                        Text("Import today's reminders from Apple Reminders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if importState == .completed {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(AppColors.accent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        }
                    } else if importState == .error {
                        Button {
                            importState = .idle
                            errorMessage = nil
                        } label: {
                            Text("Try Again")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(AppColors.accent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if importState != .completed {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var titleForState: String {
        switch importState {
        case .idle:
            return "Import Reminders"
        case .requestingAccess:
            return "Requesting Access"
        case .fetchingReminders:
            return "Fetching Reminders"
        case .analyzingCategories:
            return "AI Analysis"
        case .enhancing:
            return "AI Enhancement"
        case .importing:
            return "Importing"
        case .completed:
            return "Import Complete!"
        case .error:
            return "Import Failed"
        }
    }

    private var showProgress: Bool {
        switch importState {
        case .fetchingReminders, .analyzingCategories, .enhancing, .importing:
            return true
        default:
            return false
        }
    }

    private var isImporting: Bool {
        switch importState {
        case .requestingAccess, .fetchingReminders, .analyzingCategories, .enhancing, .importing:
            return true
        default:
            return false
        }
    }

    private func startImport() {
        Task {
            await performImport()
        }
    }

    private func performImport() async {
        // Capture toggle states at start (they're @State so can't be accessed off main actor)
        let shouldEnhance = await MainActor.run { enhanceWithAI && Constants.isAPIKeyConfigured }
        let shouldRemoveDates = await MainActor.run { removeDueDates }

        do {
            // Step 1: Request Access
            await MainActor.run {
                importState = .requestingAccess
                statusMessage = "Please grant access to Reminders..."
                progress = 0
            }

            let hasAccess = try await AppleRemindersService.shared.requestAccess()
            guard hasAccess else {
                throw AppleRemindersService.SyncError.accessDenied
            }

            // Step 2: Fetch Today's Reminders
            await MainActor.run {
                importState = .fetchingReminders
                statusMessage = "Reading today's reminders..."
                progress = 0.2
            }

            let fetched = try await AppleRemindersService.shared.fetchTodayReminders()
            importedReminders = fetched

            await MainActor.run {
                importedCount = fetched.count
                statusMessage = "Found \(fetched.count) reminders due today"
                progress = 0.4
            }

            guard !fetched.isEmpty else {
                await MainActor.run {
                    importState = .completed
                    statusMessage = "No reminders due today"
                }
                return
            }

            // Get category names for AI
            let categoryNames = await MainActor.run { categories.map { $0.name } }

            // Step 3: AI Enhancement or Categorization
            struct EnhancedData {
                var title: String
                var notes: String
                var categoryName: String?
                var context: String?
            }
            var enhancedReminders: [Int: EnhancedData] = [:]

            if shouldEnhance {
                // Full AI enhancement - update title, notes, category for each reminder
                await MainActor.run {
                    importState = .enhancing
                    statusMessage = "AI is enhancing your reminders..."
                    progress = 0.5
                }

                for (index, imported) in fetched.enumerated() {
                    do {
                        let enhanced = try await ClaudeService.shared.enhanceReminderFull(
                            title: imported.title,
                            notes: imported.notes,
                            existingCategories: categoryNames
                        )

                        enhancedReminders[index] = EnhancedData(
                            title: enhanced.title,
                            notes: enhanced.notes,
                            categoryName: enhanced.category,
                            context: enhanced.context
                        )
                    } catch {
                        // Keep original if enhancement fails
                        print("AI enhancement failed for reminder \(index): \(error)")
                    }

                    await MainActor.run {
                        let progressValue = 0.5 + (0.3 * Double(index + 1) / Double(fetched.count))
                        progress = progressValue
                        statusMessage = "Enhanced \(index + 1) of \(fetched.count) reminders..."
                    }
                }
            } else if Constants.isAPIKeyConfigured {
                // Batch categorization only (faster but no title/notes enhancement)
                await MainActor.run {
                    importState = .analyzingCategories
                    statusMessage = "AI is analyzing your reminders..."
                    progress = 0.5
                }

                let reminderData = fetched.map { (title: $0.title, notes: $0.notes, listName: $0.listName) }

                let batchSize = 30
                for batchStart in stride(from: 0, to: reminderData.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, reminderData.count)
                    let batch = Array(reminderData[batchStart..<batchEnd])

                    do {
                        let assignments = try await ClaudeService.shared.analyzeBatchForCategories(
                            reminders: batch,
                            existingCategories: categoryNames
                        )

                        for assignment in assignments {
                            let actualIndex = batchStart + assignment.reminderIndex
                            if actualIndex < fetched.count {
                                enhancedReminders[actualIndex] = EnhancedData(
                                    title: fetched[actualIndex].title,
                                    notes: fetched[actualIndex].notes,
                                    categoryName: assignment.categoryName,
                                    context: nil
                                )
                            }
                        }
                    } catch {
                        print("AI categorization failed for batch: \(error)")
                    }

                    await MainActor.run {
                        let progressValue = 0.5 + (0.3 * Double(batchEnd) / Double(reminderData.count))
                        progress = progressValue
                        statusMessage = "Analyzed \(batchEnd) of \(reminderData.count) reminders..."
                    }
                }
            }

            // Step 4: Import into SwiftData
            await MainActor.run {
                importState = .importing
                statusMessage = "Saving reminders..."
                progress = 0.8
            }

            await MainActor.run {
                for (index, imported) in fetched.enumerated() {
                    let enhanced = enhancedReminders[index]

                    // Determine final values
                    let finalTitle = enhanced?.title ?? imported.title
                    let finalNotes = enhanced?.notes ?? imported.notes
                    let finalDueDate = shouldRemoveDates ? nil : imported.dueDate

                    // Find category
                    var category: Category? = nil
                    if let categoryName = enhanced?.categoryName {
                        category = categories.first { $0.name == categoryName }
                    }

                    // If no AI assignment, try to match by list name
                    if category == nil {
                        category = categories.first { cat in
                            imported.listName.lowercased().contains(cat.name.lowercased()) ||
                            cat.name.lowercased().contains(imported.listName.lowercased())
                        }
                    }

                    let reminder = Reminder(
                        title: finalTitle,
                        notes: finalNotes,
                        dueDate: finalDueDate,
                        priority: imported.priority,
                        isCompleted: imported.isCompleted,
                        category: category
                    )

                    // Add AI context if available
                    if let context = enhanced?.context, !context.isEmpty {
                        reminder.aiEnhancedDescription = context
                    }

                    modelContext.insert(reminder)
                }

                try? modelContext.save()

                importState = .completed
                statusMessage = "Successfully imported \(fetched.count) reminders"
                progress = 1.0
                HapticManager.notification(.success)
            }

        } catch {
            await MainActor.run {
                importState = .error
                statusMessage = "Something went wrong"
                errorMessage = error.localizedDescription
                HapticManager.notification(.error)
            }
        }
    }
}

#Preview {
    ImportRemindersView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
