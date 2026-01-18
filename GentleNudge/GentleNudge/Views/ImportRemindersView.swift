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

    enum ImportState {
        case idle
        case requestingAccess
        case fetchingReminders
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
                            Toggle(isOn: $removeDueDates) {
                                HStack {
                                    Image(systemName: "calendar.badge.minus")
                                        .foregroundStyle(.orange)
                                    Text("Remove due dates")
                                }
                            }
                        }
                        .padding()
                        .background(AppColors.secondaryBackground)
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        case .fetchingReminders, .importing:
            return true
        default:
            return false
        }
    }

    private var isImporting: Bool {
        switch importState {
        case .requestingAccess, .fetchingReminders, .importing:
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
        // Capture toggle state at start
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
                progress = 0.3
            }

            let fetched = try await AppleRemindersService.shared.fetchTodayReminders()
            importedReminders = fetched

            await MainActor.run {
                importedCount = fetched.count
                statusMessage = "Found \(fetched.count) reminders due today"
                progress = 0.5
            }

            guard !fetched.isEmpty else {
                await MainActor.run {
                    importState = .completed
                    statusMessage = "No reminders due today"
                }
                return
            }

            // Step 3: Import into SwiftData
            await MainActor.run {
                importState = .importing
                statusMessage = "Saving reminders..."
                progress = 0.7
            }

            await MainActor.run {
                for imported in fetched {
                    let finalDueDate = shouldRemoveDates ? nil : imported.dueDate

                    // Try to match category by list name
                    let category = categories.first { cat in
                        imported.listName.lowercased().contains(cat.name.lowercased()) ||
                        cat.name.lowercased().contains(imported.listName.lowercased())
                    }

                    let reminder = Reminder(
                        title: imported.title,
                        notes: imported.notes,
                        dueDate: finalDueDate,
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
