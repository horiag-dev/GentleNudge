import Foundation
import SwiftData

actor BackupService {
    static let shared = BackupService()

    /// A `Sendable` capture of exactly the fields the backup serializes (mirrors
    /// `MorningBriefingService.ReminderSummary`). Built ON the main actor at the
    /// call sites, so this actor never reads live `@Model` properties (or walks
    /// the `category` relationship fault) off the main thread while the UI may
    /// be mutating them. The backup FILE format is unchanged — same JSON keys.
    struct ReminderBackupSnapshot: Sendable {
        let id: UUID
        let title: String
        let notes: String
        let priorityRaw: Int
        let isCompleted: Bool
        let createdAt: Date
        let recurrenceRaw: Int
        let hasBeenSynced: Bool
        let dueDate: Date?
        let completedAt: Date?
        let aiEnhancedDescription: String?
        let appleSyncID: String?
        let categoryName: String?
        let habitCompletionDates: [Date]

        @MainActor
        init(_ reminder: Reminder) {
            self.id = reminder.id
            self.title = reminder.title
            self.notes = reminder.notes
            self.priorityRaw = reminder.priorityRaw
            self.isCompleted = reminder.isCompleted
            self.createdAt = reminder.createdAt
            self.recurrenceRaw = reminder.recurrenceRaw
            self.hasBeenSynced = reminder.hasBeenSynced
            self.dueDate = reminder.dueDate
            self.completedAt = reminder.completedAt
            self.aiEnhancedDescription = reminder.aiEnhancedDescription
            self.appleSyncID = reminder.appleSyncID
            self.categoryName = reminder.category?.name
            self.habitCompletionDates = reminder.habitCompletionDates
        }
    }

    private let backupFolderName = "Backups"
    private let maxBackupDays = 7
    private let fileManager = FileManager.default

    private init() {}

    private var backupDirectory: URL? {
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsDir.appendingPathComponent(backupFolderName)
    }

    private func ensureBackupDirectoryExists() throws {
        guard let backupDir = backupDirectory else {
            throw BackupError.directoryNotFound
        }

        if !fileManager.fileExists(atPath: backupDir.path) {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        }
    }

    func performDailyBackup(reminders: [ReminderBackupSnapshot]) async throws {
        try ensureBackupDirectoryExists()

        guard let backupDir = backupDirectory else {
            throw BackupError.directoryNotFound
        }

        // Check if we already have a backup for today
        let todayFileName = backupFileName(for: Date())
        let todayBackupURL = backupDir.appendingPathComponent(todayFileName)

        if fileManager.fileExists(atPath: todayBackupURL.path) {
            // Already backed up today, just clean old backups
            try cleanOldBackups()
            return
        }

        // Create backup data
        let backupData = createBackupData(from: reminders)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: backupData, options: .prettyPrinted) else {
            throw BackupError.serializationFailed
        }

        // Save backup
        try jsonData.write(to: todayBackupURL)

        // Clean old backups
        try cleanOldBackups()

        print("Backup saved: \(todayFileName)")
    }

    private func createBackupData(from reminders: [ReminderBackupSnapshot]) -> [[String: Any]] {
        var backupData: [[String: Any]] = []

        for reminder in reminders {
            var item: [String: Any] = [
                "id": reminder.id.uuidString,
                "title": reminder.title,
                "notes": reminder.notes,
                "priority": reminder.priorityRaw,
                "isCompleted": reminder.isCompleted,
                "createdAt": reminder.createdAt.timeIntervalSince1970,
                "recurrence": reminder.recurrenceRaw,
                "hasBeenSynced": reminder.hasBeenSynced
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
            if let appleSyncID = reminder.appleSyncID {
                item["appleSyncID"] = appleSyncID
            }
            if let categoryName = reminder.categoryName {
                item["categoryName"] = categoryName
            }

            // Include habit completion dates for habit tracking history
            if !reminder.habitCompletionDates.isEmpty {
                item["habitCompletionDates"] = reminder.habitCompletionDates.map { $0.timeIntervalSince1970 }
            }

            backupData.append(item)
        }

        return backupData
    }

    private func backupFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "backup-\(formatter.string(from: date)).json"
    }

    private func cleanOldBackups() throws {
        guard let backupDir = backupDirectory else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -maxBackupDays, to: Date()) ?? Date()

        for fileURL in contents {
            guard fileURL.pathExtension == "json" else { continue }

            // Extract date from filename (backup-YYYY-MM-DD.json)
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            if fileName.hasPrefix("backup-") {
                let dateString = String(fileName.dropFirst(7)) // Remove "backup-"
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                if let fileDate = formatter.date(from: dateString), fileDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                    print("Deleted old backup: \(fileName)")
                }
            }
        }
    }

    func getBackupList() throws -> [(date: Date, url: URL, size: Int64)] {
        guard let backupDir = backupDirectory else { return [] }

        try ensureBackupDirectoryExists()

        let contents = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )

        var backups: [(date: Date, url: URL, size: Int64)] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for fileURL in contents {
            guard fileURL.pathExtension == "json" else { continue }

            let fileName = fileURL.deletingPathExtension().lastPathComponent
            if fileName.hasPrefix("backup-") {
                let dateString = String(fileName.dropFirst(7))
                if let fileDate = formatter.date(from: dateString) {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    let size = attributes[.size] as? Int64 ?? 0
                    backups.append((date: fileDate, url: fileURL, size: size))
                }
            }
        }

        return backups.sorted { $0.date > $1.date }
    }

    enum BackupError: LocalizedError {
        case directoryNotFound
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .directoryNotFound:
                return "Could not find backup directory"
            case .serializationFailed:
                return "Failed to serialize backup data"
            }
        }
    }
}
