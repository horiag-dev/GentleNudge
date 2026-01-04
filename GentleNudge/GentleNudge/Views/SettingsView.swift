import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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
    @State private var showingExporter = false
    @State private var exportDocument: BackupDocument?
    @State private var backupList: [(date: Date, url: URL, size: Int64)] = []
    @State private var showingDeleteAllConfirmation = false
    @State private var isMigrating = false
    @State private var migrationMessage = ""
    @State private var showingMigrationAlert = false
    @State private var iCloudSyncStatus: SyncStatus = .idle
    @State private var lastSyncTime: Date?

    // Notification settings (iOS only)
    #if os(iOS)
    @State private var notificationsEnabled = NotificationService.shared.isEnabled
    @State private var notificationTime = NotificationService.shared.notificationTime
    @State private var notificationPermissionStatus: String = "Checking..."
    @State private var isTestingNotification = false
    #endif

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
                    Text("Import reminders due today from Apple Reminders. AI will analyze and categorize them automatically.")
                }

                // Morning Notification (iOS only)
                #if os(iOS)
                Section {
                    Toggle(isOn: $notificationsEnabled) {
                        Label("Morning Summary", systemImage: "bell.badge.fill")
                    }
                    .onChange(of: notificationsEnabled) { _, newValue in
                        Task {
                            if newValue {
                                let granted = await NotificationService.shared.requestPermission()
                                if granted {
                                    NotificationService.shared.isEnabled = true
                                    updateNotificationContent()
                                } else {
                                    notificationsEnabled = false
                                }
                            } else {
                                NotificationService.shared.isEnabled = false
                            }
                            await checkNotificationPermission()
                        }
                    }

                    if notificationsEnabled {
                        DatePicker(
                            "Time",
                            selection: $notificationTime,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: notificationTime) { _, newValue in
                            NotificationService.shared.notificationTime = newValue
                            updateNotificationContent()
                        }
                    }

                    HStack {
                        Text("Permission")
                        Spacer()
                        Text(notificationPermissionStatus)
                            .foregroundStyle(notificationPermissionStatus == "Authorized" ? .green : .orange)
                    }

                    Button {
                        testNotification()
                    } label: {
                        HStack {
                            Label("Test Notification", systemImage: "bell.and.waves.left.and.right")
                            Spacer()
                            if isTestingNotification {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingNotification)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get a morning reminder of items that need attention. The notification shows overdue items, items due today, and high priority tasks.")
                }
                #endif

                // iCloud Sync
                Section {
                    HStack {
                        Label("Storage Mode", systemImage: "externaldrive.fill")
                        Spacer()
                        Text(AppState.shared.storageMode.rawValue)
                            .foregroundStyle(AppState.shared.storageMode == .cloudKit ? .green : .orange)
                    }

                    HStack {
                        Label("iCloud Account", systemImage: "icloud.fill")
                        Spacer()
                        if FileManager.default.ubiquityIdentityToken != nil {
                            Text("Signed In")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not signed in")
                                .foregroundStyle(.red)
                        }
                    }

                    HStack {
                        Text("Reminders in database")
                        Spacer()
                        Text("\(reminders.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Categories")
                        Spacer()
                        Text("\(categories.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        forceiCloudSync()
                    } label: {
                        HStack {
                            Label("Force Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                            Spacer()
                            if iCloudSyncStatus == .syncing {
                                ProgressView()
                            } else if iCloudSyncStatus == .success {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(iCloudSyncStatus == .syncing)

                    if let lastSync = lastSyncTime {
                        HStack {
                            Text("Last sync")
                            Spacer()
                            Text(lastSync.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        migrateToiCloud()
                    } label: {
                        HStack {
                            Label("Migrate Local Data to iCloud", systemImage: "icloud.and.arrow.up")
                            Spacer()
                            if isMigrating {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isMigrating)

                    Button(role: .destructive) {
                        resetCloudKitSync()
                    } label: {
                        Label("Reset Sync State", systemImage: "arrow.counterclockwise.icloud")
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Force Sync pushes changes. Reset Sync clears the local sync token if sync gets stuck (data is preserved).")
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
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

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

                // Automatic Backups
                Section {
                    HStack {
                        Label("Auto Backup", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("Daily, 7 days")
                            .foregroundStyle(.secondary)
                    }

                    if backupList.isEmpty {
                        Text("No backups yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(backupList, id: \.url) { backup in
                            HStack {
                                Text(backup.date.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(formatFileSize(backup.size))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        manualBackup()
                    } label: {
                        Label("Backup Now", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Local Backups")
                } footer: {
                    Text("Backups are saved automatically each day. Last 7 days are kept.")
                }

                // Data Management
                Section {
                    Button {
                        exportBackup()
                    } label: {
                        Label("Export to File", systemImage: "square.and.arrow.up")
                    }

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

                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Reminders", systemImage: "trash.fill")
                    }

                    Button {
                        cleanDuplicateCategories()
                    } label: {
                        Label("Clean Duplicate Categories", systemImage: "sparkles")
                    }

                    Button {
                        updateCategoryColors()
                    } label: {
                        Label("Update Category Colors", systemImage: "paintpalette")
                    }

                    Button {
                        recoverRecurringTasks()
                    } label: {
                        Label("Recover Recurring Tasks", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Recover Recurring Tasks: If recurring reminders were completed without creating the next occurrence, this will recreate them.")
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.1.0")
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
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            #endif
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
            .confirmationDialog("Delete All Reminders", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All", role: .destructive) {
                    deleteAllReminders()
                }
            } message: {
                Text("This will permanently delete ALL reminders. This action cannot be undone.")
            }
            .sheet(isPresented: $showingImport) {
                ImportRemindersView()
            }
            .alert("Migration Result", isPresented: $showingMigrationAlert) {
                Button("OK") {}
            } message: {
                Text(migrationMessage)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "GentleNudge-Backup-\(Date().formatted(.dateTime.year().month().day()))"
            ) { result in
                switch result {
                case .success:
                    HapticManager.notification(.success)
                case .failure:
                    HapticManager.notification(.error)
                }
            }
            .onAppear {
                loadBackupList()
                #if os(iOS)
                Task {
                    await checkNotificationPermission()
                }
                #endif
            }
        }
    }

    private func loadBackupList() {
        Task {
            do {
                let list = try await BackupService.shared.getBackupList()
                await MainActor.run {
                    backupList = list
                }
            } catch {
                print("Failed to load backup list: \(error)")
            }
        }
    }

    private func manualBackup() {
        Task {
            do {
                try await BackupService.shared.performDailyBackup(reminders: reminders)
                loadBackupList()
                await MainActor.run {
                    HapticManager.notification(.success)
                }
            } catch {
                await MainActor.run {
                    HapticManager.notification(.error)
                }
            }
        }
    }

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func exportBackup() {
        var backupData: [[String: Any]] = []

        for reminder in reminders {
            var item: [String: Any] = [
                "id": reminder.id.uuidString,
                "title": reminder.title,
                "notes": reminder.notes,
                "priority": reminder.priorityRaw,
                "isCompleted": reminder.isCompleted,
                "createdAt": reminder.createdAt.timeIntervalSince1970,
                "recurrence": reminder.recurrenceRaw
            ]

            if let dueDate = reminder.dueDate {
                item["dueDate"] = dueDate.timeIntervalSince1970
            }
            if let completedAt = reminder.completedAt {
                item["completedAt"] = completedAt.timeIntervalSince1970
            }
            if let aiDescription = reminder.aiEnhancedDescription {
                item["aiEnhancedDescription"] = aiDescription
            }
            if let category = reminder.category {
                item["categoryName"] = category.name
            }

            backupData.append(item)
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: backupData, options: .prettyPrinted) {
            exportDocument = BackupDocument(data: jsonData)
            showingExporter = true
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

    private func deleteAllReminders() {
        for reminder in reminders {
            modelContext.delete(reminder)
        }
        try? modelContext.save()
        HapticManager.notification(.success)
    }

    private func recoverRecurringTasks() {
        // Find completed recurring reminders that don't have an active next occurrence
        let completedRecurring = reminders.filter { $0.isCompleted && $0.isRecurring }

        var recoveredCount = 0

        for reminder in completedRecurring {
            // Check if there's already an active (non-completed) reminder with the same title and recurrence
            let hasActiveOccurrence = reminders.contains { r in
                !r.isCompleted &&
                r.title == reminder.title &&
                r.recurrence == reminder.recurrence
            }

            if !hasActiveOccurrence {
                // Create the next occurrence from the completed reminder
                if let nextReminder = reminder.createNextOccurrence() {
                    // Adjust the due date to be in the future if needed
                    var adjustedReminder = nextReminder

                    // Keep advancing until the due date is in the future
                    while let dueDate = adjustedReminder.dueDate, dueDate < Date() {
                        if let advancedReminder = adjustedReminder.createNextOccurrence() {
                            adjustedReminder = advancedReminder
                        } else {
                            break
                        }
                    }

                    modelContext.insert(adjustedReminder)
                    recoveredCount += 1
                }
            }
        }

        try? modelContext.save()

        if recoveredCount > 0 {
            syncMessage = "Recovered \(recoveredCount) recurring task\(recoveredCount == 1 ? "" : "s")"
        } else {
            syncMessage = "No recurring tasks needed recovery"
        }
        showingSyncAlert = true
        HapticManager.notification(.success)
    }

    private func cleanDuplicateCategories() {
        var seenNames: Set<String> = []
        var duplicatesToDelete: [Category] = []

        // Sort by sortOrder to keep the original ones
        let sortedCategories = categories.sorted { $0.sortOrder < $1.sortOrder }

        for category in sortedCategories {
            if seenNames.contains(category.name) {
                // This is a duplicate - mark for deletion
                duplicatesToDelete.append(category)
            } else {
                seenNames.insert(category.name)
            }
        }

        // Delete duplicates
        for duplicate in duplicatesToDelete {
            // Move reminders to the original category first
            if let originalCategory = categories.first(where: { $0.name == duplicate.name && !duplicatesToDelete.contains($0) }) {
                for reminder in reminders where reminder.category?.id == duplicate.id {
                    reminder.category = originalCategory
                }
            }
            modelContext.delete(duplicate)
        }

        try? modelContext.save()
        HapticManager.notification(.success)
    }

    private func updateCategoryColors() {
        // Updated color scheme
        let colorUpdates: [String: (color: String, icon: String)] = [
            "Habits": ("red", "heart.circle.fill"),
            "Today": ("yellow", "sun.max.fill"),
            "House": ("green", "house.fill"),
            "Photos": ("purple", "photo.fill"),
            "Finance": ("teal", "dollarsign.circle.fill"),
            "To Read": ("blue", "book.fill"),
            "Startup": ("orange", "lightbulb.fill"),
            "Explore": ("indigo", "safari.fill"),
            "GenAI": ("pink", "sparkles"),
            "Misc": ("mint", "tray.fill"),
        ]

        for category in categories {
            if let update = colorUpdates[category.name] {
                category.colorName = update.color
                category.icon = update.icon
            }
        }

        // Add "Today" category if it doesn't exist
        if !categories.contains(where: { $0.name == "Today" }) {
            let todayCategory = Category(
                name: "Today",
                icon: "sun.max.fill",
                colorName: "yellow",
                isDefault: true,
                sortOrder: 1
            )
            modelContext.insert(todayCategory)
        }

        try? modelContext.save()
        HapticManager.notification(.success)
    }

    private func resetCloudKitSync() {
        // Reset the CloudKit sync by deleting the local store's sync metadata
        // This forces a full re-sync from CloudKit
        Task {
            do {
                // Save any pending changes first
                try modelContext.save()

                // Post notification to reset sync (CoreData handles this)
                NotificationCenter.default.post(
                    name: NSNotification.Name("NSCloudKitMirroringDelegateWillResetSyncNotificationName"),
                    object: nil,
                    userInfo: ["reason": "ManualReset"]
                )

                await MainActor.run {
                    HapticManager.notification(.success)
                    lastSyncTime = nil
                }
            } catch {
                await MainActor.run {
                    HapticManager.notification(.error)
                }
            }
        }
    }

    private func forceiCloudSync() {
        iCloudSyncStatus = .syncing

        Task {
            do {
                // Save the context to push any pending changes
                try modelContext.save()

                // Touch all reminders to trigger CloudKit sync
                // This forces CloudKit to re-evaluate all records
                for reminder in reminders {
                    // Update a non-visible property to trigger sync
                    reminder.hasBeenSynced = true
                }

                try modelContext.save()

                // Small delay to allow CloudKit to process
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

                await MainActor.run {
                    iCloudSyncStatus = .success
                    lastSyncTime = Date()
                    HapticManager.notification(.success)

                    // Reset status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        iCloudSyncStatus = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    iCloudSyncStatus = .error
                    HapticManager.notification(.error)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        iCloudSyncStatus = .idle
                    }
                }
            }
        }
    }

    private func migrateToiCloud() {
        isMigrating = true

        Task {
            do {
                // Create a container pointing to local-only database
                let schema = Schema([Reminder.self, Category.self])
                let localConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .none
                )

                let localContainer = try ModelContainer(for: schema, configurations: [localConfig])
                let localContext = ModelContext(localContainer)

                // Fetch from local database
                let localReminders = try localContext.fetch(FetchDescriptor<Reminder>())
                let localCategories = try localContext.fetch(FetchDescriptor<Category>())

                guard !localReminders.isEmpty else {
                    await MainActor.run {
                        isMigrating = false
                        migrationMessage = "No local reminders found to migrate."
                        showingMigrationAlert = true
                    }
                    return
                }

                await MainActor.run {
                    // Build category mapping (local name -> current category)
                    var categoryMap: [String: Category] = [:]
                    for category in categories {
                        categoryMap[category.name] = category
                    }

                    // Create any missing categories
                    for localCat in localCategories {
                        if categoryMap[localCat.name] == nil {
                            let newCat = Category(
                                name: localCat.name,
                                icon: localCat.icon,
                                colorName: localCat.colorName,
                                sortOrder: localCat.sortOrder
                            )
                            modelContext.insert(newCat)
                            categoryMap[localCat.name] = newCat
                        }
                    }

                    // Copy reminders
                    var copiedCount = 0
                    for localReminder in localReminders {
                        // Check if already exists (by title + created date)
                        let exists = reminders.contains { existing in
                            existing.title == localReminder.title &&
                            existing.createdAt.timeIntervalSince(localReminder.createdAt) < 1
                        }

                        if !exists {
                            let newReminder = Reminder(
                                title: localReminder.title,
                                notes: localReminder.notes,
                                dueDate: localReminder.dueDate,
                                priority: localReminder.priority,
                                category: categoryMap[localReminder.category?.name ?? ""],
                                recurrence: localReminder.recurrence
                            )
                            newReminder.isCompleted = localReminder.isCompleted
                            newReminder.completedAt = localReminder.completedAt
                            newReminder.aiEnhancedDescription = localReminder.aiEnhancedDescription

                            modelContext.insert(newReminder)
                            copiedCount += 1
                        }
                    }

                    try? modelContext.save()

                    isMigrating = false
                    migrationMessage = "Migrated \(copiedCount) reminders to iCloud. They will sync to your other devices."
                    showingMigrationAlert = true
                    HapticManager.notification(.success)
                }
            } catch {
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = "Migration failed: \(error.localizedDescription)"
                    showingMigrationAlert = true
                    HapticManager.notification(.error)
                }
            }
        }
    }

    // MARK: - Notification Functions (iOS only)

    #if os(iOS)
    private func checkNotificationPermission() async {
        let status = await NotificationService.shared.checkPermissionStatus()
        await MainActor.run {
            switch status {
            case .authorized:
                notificationPermissionStatus = "Authorized"
            case .denied:
                notificationPermissionStatus = "Denied"
            case .notDetermined:
                notificationPermissionStatus = "Not Set"
            case .provisional:
                notificationPermissionStatus = "Provisional"
            case .ephemeral:
                notificationPermissionStatus = "Ephemeral"
            @unknown default:
                notificationPermissionStatus = "Unknown"
            }
        }
    }

    private func testNotification() {
        isTestingNotification = true

        // Calculate needs attention items
        let needsAttention = reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            return reminder.isOverdue || reminder.isDueToday || reminder.priority == .urgent
        }

        // Get top item titles
        let topItems = needsAttention.prefix(3).map { $0.title }

        Task {
            await NotificationService.shared.triggerTestNotification(
                needsAttentionCount: needsAttention.count,
                topItems: Array(topItems)
            )

            await MainActor.run {
                isTestingNotification = false
                HapticManager.notification(.success)
            }
        }
    }

    private func updateNotificationContent() {
        // Calculate needs attention items
        let needsAttention = reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            return reminder.isOverdue || reminder.isDueToday || reminder.priority == .urgent
        }

        // Get top item titles
        let topItems = needsAttention.prefix(3).map { $0.title }

        NotificationService.shared.updateScheduledNotificationContent(
            needsAttentionCount: needsAttention.count,
            topItems: Array(topItems)
        )
    }
    #endif

    private func generateTestReminders() {
        let calendar = Calendar.current

        // Habit data with completion rate (0.0 to 1.0 - how often they complete it)
        let habitData: [(title: String, notes: String, completionRate: Double)] = [
            ("Exercise", "30 min workout", 0.7),
            ("Drink water", "8 glasses", 0.9),
            ("Read", "At least 20 pages", 0.5),
            ("Meditate", "10 min session", 0.4),
            ("Journal", "Reflect on the day", 0.6),
        ]

        // Create habits with history
        if let habitsCategory = categories.first(where: { $0.name == "Habits" }) {
            for data in habitData {
                let habit = Reminder(
                    title: data.title,
                    notes: data.notes,
                    dueDate: nil,
                    priority: .normal,
                    category: habitsCategory,
                    recurrence: .daily
                )

                // Generate completion history for last 90 days
                for daysAgo in 0..<90 {
                    if Double.random(in: 0...1) < data.completionRate {
                        if let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) {
                            habit.habitCompletionDates.append(date)
                        }
                    }
                }

                // Mark today as completed based on rate
                if Double.random(in: 0...1) < data.completionRate {
                    habit.completedAt = Date()
                }

                modelContext.insert(habit)
            }
        }

        // Test data for other categories
        // Most items don't have due dates - this is a "keep track" app, not urgent todos
        // nil daysOffset means no due date
        let testData: [(categoryName: String, reminders: [(title: String, notes: String, daysOffset: Int?, priority: ReminderPriority, recurrence: RecurrenceType)])] = [
            ("Today", [
                ("Call dentist", "Schedule cleaning", 0, .normal, .none),
                ("Submit expense report", "From last trip", 0, .urgent, .none),
                ("Pick up dry cleaning", "Before 6pm", 0, .normal, .none),
            ]),
            ("To Read", [
                ("Atomic Habits", "Finish chapter 5", nil, .normal, .none),
                ("The Mom Test", "Customer interview techniques", nil, .normal, .none),
                ("Saved Pocket articles", "50+ items in queue", nil, .normal, .none),
                ("Stratechery newsletter", "Backlog of 10 issues", nil, .normal, .none),
            ]),
            ("Startup", [
                ("Update pitch deck", "Add Q4 metrics", nil, .normal, .none),
                ("Customer discovery calls", "Talk to 5 more users", nil, .normal, .none),
                ("Roadmap planning", "Q1 priorities", nil, .normal, .none),
                ("Competitor analysis", "Check Product Hunt launches", nil, .normal, .none),
                ("Investor update", "Monthly email", 15, .normal, .monthly),
            ]),
            ("Finance", [
                ("Review subscriptions", "Cancel unused ones", nil, .normal, .none),
                ("Tax documents", "Gather for accountant", 7, .urgent, .none),
                ("Rebalance portfolio", "Check allocation", nil, .normal, .none),
            ]),
            ("House", [
                ("Fix leaky faucet", "Kitchen sink", nil, .normal, .none),
                ("Organize garage", "Donate old stuff", nil, .normal, .none),
                ("Water plants", "All indoor plants", nil, .normal, .weekly),
            ]),
            ("Photos", [
                ("Backup phone photos", "To external drive", nil, .normal, .none),
                ("Edit vacation pics", "Apply presets", nil, .normal, .none),
                ("Print family photos", "For grandma", nil, .normal, .none),
                ("Organize photo library", "Delete duplicates", nil, .normal, .none),
            ]),
            ("Explore", [
                ("New ramen place", "Downtown location", nil, .normal, .none),
                ("Hiking trail", "Mt. Tamalpais", nil, .normal, .none),
                ("Cooking class", "Italian cuisine", nil, .normal, .none),
                ("Art museum exhibit", "Opens next month", nil, .normal, .none),
            ]),
            ("GenAI", [
                ("Claude vision API", "Test with screenshots", nil, .normal, .none),
                ("Build demo app", "Showcase for meetup", nil, .normal, .none),
                ("Prompt engineering", "Improve system prompts", nil, .normal, .none),
                ("AI paper reading", "Attention is all you need", nil, .normal, .none),
            ]),
            ("Misc", [
                ("Organize bookmarks", "Browser cleanup", nil, .normal, .none),
                ("Update LinkedIn", "Add recent projects", nil, .normal, .none),
                ("Email inbox zero", "Archive old threads", nil, .normal, .none),
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

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
