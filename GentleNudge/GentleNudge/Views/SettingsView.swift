import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var syncStatus: SyncStatus = .idle
    @State private var showingSyncAlert = false
    @State private var syncMessage = ""
    @State private var showingResetConfirmation = false
    @State private var showingImport = false
    @State private var showingGenerateConfirmation = false
    @State private var apiKeyInput = ""
    @State private var showingAPIKeyField = false

    enum SyncStatus {
        case idle
        case syncing
        case success
        case error
    }

    var body: some View {
        NavigationStack {
            List {
                // Import Section
                Section {
                    Button {
                        showingImport = true
                    } label: {
                        HStack {
                            Label("Import from Apple Reminders", systemImage: "square.and.arrow.down")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("One-time import of your existing Apple Reminders. AI will analyze and categorize them automatically.")
                }

                // Apple Reminders Sync
                Section {
                    HStack {
                        Label("Apple Reminders", systemImage: "checkmark.circle.fill")
                        Spacer()
                        switch AppleRemindersService.shared.checkAuthorizationStatus() {
                        case .authorized:
                            Text("Connected")
                                .foregroundStyle(.green)
                        case .denied:
                            Text("Denied")
                                .foregroundStyle(.red)
                        case .notDetermined:
                            Text("Not Set")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        requestRemindersAccess()
                    } label: {
                        Label("Grant Access", systemImage: "lock.open.fill")
                    }

                    Button {
                        syncToAppleReminders()
                    } label: {
                        HStack {
                            Label("Sync All to Apple Reminders", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if syncStatus == .syncing {
                                ProgressView()
                            } else if syncStatus == .success {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(syncStatus == .syncing)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Sync your reminders to Apple's built-in Reminders app as a backup. A list called '\(Constants.appleRemindersListName)' will be created.")
                }

                // AI Settings
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(Constants.isAPIKeyConfigured ? "Configured" : "Not configured")
                            .foregroundStyle(Constants.isAPIKeyConfigured ? .green : .red)
                    }

                    if showingAPIKeyField {
                        SecureField("Enter API Key", text: $apiKeyInput)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            if !apiKeyInput.isEmpty {
                                Constants.claudeAPIKey = apiKeyInput
                                apiKeyInput = ""
                                showingAPIKeyField = false
                                HapticManager.notification(.success)
                            }
                        } label: {
                            Label("Save API Key", systemImage: "checkmark.circle.fill")
                        }
                        .disabled(apiKeyInput.isEmpty)

                        Button(role: .cancel) {
                            apiKeyInput = ""
                            showingAPIKeyField = false
                        } label: {
                            Text("Cancel")
                        }
                    } else {
                        Button {
                            showingAPIKeyField = true
                        } label: {
                            Label(Constants.isAPIKeyConfigured ? "Update API Key" : "Enter API Key", systemImage: "key.fill")
                        }
                    }

                    Link(destination: URL(string: "https://console.anthropic.com/")!) {
                        Label("Get API Key", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("AI Enhancement")
                } footer: {
                    Text("Enter your Claude API key to enable AI features like reminder enhancement and category suggestions.")
                }

                // Statistics
                Section("Statistics") {
                    StatRow(title: "Total Reminders", value: "\(reminders.count)")
                    StatRow(title: "Active", value: "\(reminders.filter { !$0.isCompleted }.count)")
                    StatRow(title: "Completed", value: "\(reminders.filter { $0.isCompleted }.count)")
                    StatRow(title: "Overdue", value: "\(reminders.filter { $0.isOverdue }.count)")
                    StatRow(title: "AI Enhanced", value: "\(reminders.filter { $0.aiEnhancedDescription != nil }.count)")
                }

                // Data Management
                Section {
                    Button {
                        showingGenerateConfirmation = true
                    } label: {
                        Label("Generate Test Reminders", systemImage: "wand.and.stars")
                    }

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Delete All Completed", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Generate sample reminders across all categories to test the app.")
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Built with")
                        Spacer()
                        Text("SwiftUI + Claude AI")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Sync Result", isPresented: $showingSyncAlert) {
                Button("OK") {}
            } message: {
                Text(syncMessage)
            }
            .confirmationDialog("Delete Completed Reminders", isPresented: $showingResetConfirmation) {
                Button("Delete All Completed", role: .destructive) {
                    deleteCompleted()
                }
            } message: {
                Text("This will permanently delete all completed reminders.")
            }
            .confirmationDialog("Generate Test Reminders", isPresented: $showingGenerateConfirmation) {
                Button("Generate") {
                    generateTestReminders()
                }
            } message: {
                Text("This will create sample reminders across all categories, including recurring ones.")
            }
            .sheet(isPresented: $showingImport) {
                ImportRemindersView()
            }
        }
    }

    private func requestRemindersAccess() {
        Task {
            do {
                let granted = try await AppleRemindersService.shared.requestAccess()
                await MainActor.run {
                    if granted {
                        HapticManager.notification(.success)
                    } else {
                        HapticManager.notification(.error)
                    }
                }
            } catch {
                await MainActor.run {
                    HapticManager.notification(.error)
                }
            }
        }
    }

    private func syncToAppleReminders() {
        syncStatus = .syncing

        Task {
            do {
                let mapping = try await AppleRemindersService.shared.syncAllReminders(reminders)

                await MainActor.run {
                    // Update sync IDs
                    for reminder in reminders {
                        if let syncID = mapping[reminder.id.uuidString] {
                            reminder.appleSyncID = syncID
                            reminder.hasBeenSynced = true
                        }
                    }

                    syncStatus = .success
                    syncMessage = "Successfully synced \(reminders.count) reminders to Apple Reminders."
                    showingSyncAlert = true
                    HapticManager.notification(.success)

                    // Reset status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        syncStatus = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    syncStatus = .error
                    syncMessage = error.localizedDescription
                    showingSyncAlert = true
                    HapticManager.notification(.error)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        syncStatus = .idle
                    }
                }
            }
        }
    }

    private func deleteCompleted() {
        let completed = reminders.filter { $0.isCompleted }
        for reminder in completed {
            modelContext.delete(reminder)
        }
        HapticManager.notification(.success)
    }

    private func generateTestReminders() {
        let calendar = Calendar.current

        // Test data for each category
        // Most items don't have due dates - this is a "keep track" app, not urgent todos
        // nil daysOffset means no due date
        let testData: [(categoryName: String, reminders: [(title: String, notes: String, daysOffset: Int?, priority: ReminderPriority, recurrence: RecurrenceType)])] = [
            ("Habits", [
                ("Exercise", "30 min workout", 0, .none, .daily),
                ("Drink water", "8 glasses", 0, .none, .daily),
                ("Read", "At least 20 pages", 0, .none, .daily),
                ("Meditate", "10 min session", 0, .none, .daily),
                ("Journal", "Reflect on the day", 0, .none, .daily),
            ]),
            ("Today", [
                ("Call dentist", "Reschedule appointment", 0, .medium, .none),
            ]),
            ("To Read", [
                ("Atomic Habits", "Finish chapter 5", nil, .none, .none),
                ("The Mom Test", "Customer interview techniques", nil, .none, .none),
                ("Saved Pocket articles", "50+ items in queue", nil, .none, .none),
                ("Stratechery newsletter", "Backlog of 10 issues", nil, .none, .none),
            ]),
            ("Startup", [
                ("Update pitch deck", "Add Q4 metrics", nil, .none, .none),
                ("Customer discovery calls", "Talk to 5 more users", nil, .none, .none),
                ("Roadmap planning", "Q1 priorities", nil, .none, .none),
                ("Competitor analysis", "Check Product Hunt launches", nil, .none, .none),
                ("Investor update", "Monthly email", 15, .medium, .monthly),
            ]),
            ("Finance", [
                ("Review subscriptions", "Cancel unused ones", nil, .none, .none),
                ("Tax documents", "Gather for accountant", nil, .none, .none),
                ("Rebalance portfolio", "Check allocation", nil, .none, .none),
            ]),
            ("House", [
                ("Fix leaky faucet", "Kitchen sink", nil, .none, .none),
                ("Organize garage", "Donate old stuff", nil, .none, .none),
                ("Water plants", "All indoor plants", nil, .none, .weekly),
            ]),
            ("Photos", [
                ("Backup phone photos", "To external drive", nil, .none, .none),
                ("Edit vacation pics", "Apply presets", nil, .none, .none),
                ("Print family photos", "For grandma", nil, .none, .none),
                ("Organize photo library", "Delete duplicates", nil, .none, .none),
            ]),
            ("Explore", [
                ("New ramen place", "Downtown location", nil, .none, .none),
                ("Hiking trail", "Mt. Tamalpais", nil, .none, .none),
                ("Cooking class", "Italian cuisine", nil, .none, .none),
                ("Art museum exhibit", "Opens next month", nil, .none, .none),
            ]),
            ("GenAI", [
                ("Claude vision API", "Test with screenshots", nil, .none, .none),
                ("Build demo app", "Showcase for meetup", nil, .none, .none),
                ("Prompt engineering", "Improve system prompts", nil, .none, .none),
                ("AI paper reading", "Attention is all you need", nil, .none, .none),
            ]),
            ("Misc", [
                ("Organize bookmarks", "Browser cleanup", nil, .none, .none),
                ("Update LinkedIn", "Add recent projects", nil, .none, .none),
                ("Email inbox zero", "Archive old threads", nil, .none, .none),
            ]),
        ]

        for (categoryName, reminderData) in testData {
            guard let category = categories.first(where: { $0.name == categoryName }) else { continue }

            for data in reminderData {
                var dueDateWithTime: Date? = nil
                if let daysOffset = data.daysOffset {
                    let dueDate = calendar.date(byAdding: .day, value: daysOffset, to: Date())
                    dueDateWithTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dueDate ?? Date())
                }

                let reminder = Reminder(
                    title: data.title,
                    notes: data.notes,
                    dueDate: dueDateWithTime,
                    priority: data.priority,
                    category: category,
                    recurrence: data.recurrence
                )
                modelContext.insert(reminder)
            }
        }

        try? modelContext.save()
        HapticManager.notification(.success)
    }
}

struct StatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
