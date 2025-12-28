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

    enum ImportState {
        case idle
        case requestingAccess
        case fetchingReminders
        case analyzingCategories
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

                        Text("This will import all your Apple Reminders and use AI to categorize them.")
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
                    if importState == .idle || importState == .error {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
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
        case .fetchingReminders, .analyzingCategories, .importing:
            return true
        default:
            return false
        }
    }

    private var isImporting: Bool {
        switch importState {
        case .requestingAccess, .fetchingReminders, .analyzingCategories, .importing:
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

            // Step 2: Fetch Reminders
            await MainActor.run {
                importState = .fetchingReminders
                statusMessage = "Reading your reminders..."
                progress = 0.2
            }

            let fetched = try await AppleRemindersService.shared.fetchAllReminders()
            importedReminders = fetched

            await MainActor.run {
                importedCount = fetched.count
                statusMessage = "Found \(fetched.count) reminders"
                progress = 0.4
            }

            guard !fetched.isEmpty else {
                await MainActor.run {
                    importState = .completed
                    statusMessage = "No reminders to import"
                }
                return
            }

            // Step 3: Analyze with AI (if API key is configured)
            var categoryAssignments: [Int: String] = [:]

            if Constants.isAPIKeyConfigured {
                await MainActor.run {
                    importState = .analyzingCategories
                    statusMessage = "AI is analyzing your reminders..."
                    progress = 0.5
                }

                let categoryNames = categories.map { $0.name }
                let reminderData = fetched.map { (title: $0.title, notes: $0.notes, listName: $0.listName) }

                // Process in batches of 30 to avoid token limits
                let batchSize = 30
                for batchStart in stride(from: 0, to: reminderData.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, reminderData.count)
                    let batch = Array(reminderData[batchStart..<batchEnd])
                    let batchIndices = Array(batchStart..<batchEnd)

                    do {
                        let assignments = try await ClaudeService.shared.analyzeBatchForCategories(
                            reminders: batch,
                            existingCategories: categoryNames
                        )

                        for assignment in assignments {
                            let actualIndex = batchStart + assignment.reminderIndex
                            if actualIndex < fetched.count {
                                categoryAssignments[actualIndex] = assignment.categoryName
                            }
                        }
                    } catch {
                        // Continue without AI categorization for this batch
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
                    // Find category
                    var category: Category? = nil
                    if let categoryName = categoryAssignments[index] {
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
                        title: imported.title,
                        notes: imported.notes,
                        dueDate: imported.dueDate,
                        priority: imported.priority,
                        isCompleted: imported.isCompleted,
                        category: category
                    )

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
