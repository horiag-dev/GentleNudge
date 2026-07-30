import Foundation
import SwiftData

// MARK: - Snapshots

/// A `Sendable` capture of exactly the fields the backup serializes (mirrors
/// `MorningBriefingService.ReminderSummary`). Built ON the main actor at the
/// call sites, so the backup actor never reads live `@Model` properties (or walks
/// the `category` relationship fault) off the main thread while the UI may be
/// mutating them.
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
    // Added with format v2 — these were silently absent from v1 backups, so a
    // restore from an old file would have quietly dropped them.
    let isInProgress: Bool
    let isFocusHabit: Bool
    let recurrenceAnchorDay: Int?

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
        self.isInProgress = reminder.isInProgress
        self.isFocusHabit = reminder.isFocusHabit
        self.recurrenceAnchorDay = reminder.recurrenceAnchorDay
    }

    /// Memberwise init for the decode path (restoring from a file).
    init(
        id: UUID,
        title: String,
        notes: String,
        priorityRaw: Int,
        isCompleted: Bool,
        createdAt: Date,
        recurrenceRaw: Int,
        hasBeenSynced: Bool,
        dueDate: Date?,
        completedAt: Date?,
        aiEnhancedDescription: String?,
        appleSyncID: String?,
        categoryName: String?,
        habitCompletionDates: [Date],
        isInProgress: Bool,
        isFocusHabit: Bool,
        recurrenceAnchorDay: Int?
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priorityRaw = priorityRaw
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.recurrenceRaw = recurrenceRaw
        self.hasBeenSynced = hasBeenSynced
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.aiEnhancedDescription = aiEnhancedDescription
        self.appleSyncID = appleSyncID
        self.categoryName = categoryName
        self.habitCompletionDates = habitCompletionDates
        self.isInProgress = isInProgress
        self.isFocusHabit = isFocusHabit
        self.recurrenceAnchorDay = recurrenceAnchorDay
    }
}

/// Categories are backed up as entities from v2 on. v1 stored only each
/// reminder's category *name*, so restoring into an empty store produced
/// reminders whose categories had lost their icon, color, and order.
struct CategoryBackupSnapshot: Sendable {
    let id: UUID
    let name: String
    let icon: String
    let colorName: String
    let isDefault: Bool
    let sortOrder: Int
    let isHabitCategory: Bool

    @MainActor
    init(_ category: Category) {
        self.id = category.id
        self.name = category.name
        self.icon = category.icon
        self.colorName = category.colorName
        self.isDefault = category.isDefault
        self.sortOrder = category.sortOrder
        self.isHabitCategory = category.isHabitCategory
    }

    init(id: UUID, name: String, icon: String, colorName: String, isDefault: Bool, sortOrder: Int, isHabitCategory: Bool) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorName = colorName
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.isHabitCategory = isHabitCategory
    }
}

/// What the assistant has learned about the user — as irreplaceable as the
/// reminders, and not covered by v1 backups at all.
struct MemoryBackupSnapshot: Sendable {
    let id: UUID
    let content: String
    let kind: String
    let createdAt: Date
    let updatedAt: Date

    @MainActor
    init(_ memory: UserMemory) {
        self.id = memory.id
        self.content = memory.content
        self.kind = memory.kind
        self.createdAt = memory.createdAt
        self.updatedAt = memory.updatedAt
    }

    init(id: UUID, content: String, kind: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.content = content
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Everything one backup file holds.
struct BackupContents: Sendable {
    let formatVersion: Int
    let createdAt: Date?
    let reminders: [ReminderBackupSnapshot]
    let categories: [CategoryBackupSnapshot]
    let memories: [MemoryBackupSnapshot]

    var isEmpty: Bool {
        reminders.isEmpty && categories.isEmpty && memories.isEmpty
    }
}

// MARK: - Wire format (Codable DTOs)

/// v2 envelope. v1 files were a bare top-level array of reminder objects and are
/// still readable — see `BackupService.decode(_:)`. The reminder keys are
/// unchanged from v1 so a v1 reader still understands the reminders in a v2 file.
private struct BackupEnvelopeDTO: Codable {
    var version: Int
    var createdAt: Double
    var reminders: [ReminderDTO]
    var categories: [CategoryDTO]
    var memories: [MemoryDTO]
}

private struct ReminderDTO: Codable {
    var id: String
    var title: String
    var notes: String
    var priority: Int
    var isCompleted: Bool
    var createdAt: Double
    var recurrence: Int
    var hasBeenSynced: Bool?
    var dueDate: Double?
    var completedAt: Double?
    var aiEnhancedDescription: String?
    var appleSyncID: String?
    var categoryName: String?
    var habitCompletionDates: [Double]?
    var isInProgress: Bool?
    var isFocusHabit: Bool?
    var recurrenceAnchorDay: Int?

    init(_ snapshot: ReminderBackupSnapshot) {
        id = snapshot.id.uuidString
        title = snapshot.title
        notes = snapshot.notes
        priority = snapshot.priorityRaw
        isCompleted = snapshot.isCompleted
        createdAt = snapshot.createdAt.timeIntervalSince1970
        recurrence = snapshot.recurrenceRaw
        hasBeenSynced = snapshot.hasBeenSynced
        dueDate = snapshot.dueDate?.timeIntervalSince1970
        completedAt = snapshot.completedAt?.timeIntervalSince1970
        aiEnhancedDescription = snapshot.aiEnhancedDescription
        appleSyncID = snapshot.appleSyncID
        categoryName = snapshot.categoryName
        habitCompletionDates = snapshot.habitCompletionDates.isEmpty
            ? nil
            : snapshot.habitCompletionDates.map { $0.timeIntervalSince1970 }
        isInProgress = snapshot.isInProgress
        isFocusHabit = snapshot.isFocusHabit
        recurrenceAnchorDay = snapshot.recurrenceAnchorDay
    }

    /// Nil for a row with no parsable id — one corrupt entry is skipped rather
    /// than failing the whole restore.
    var snapshot: ReminderBackupSnapshot? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return ReminderBackupSnapshot(
            id: uuid,
            title: title,
            notes: notes,
            priorityRaw: priority,
            isCompleted: isCompleted,
            createdAt: Date(timeIntervalSince1970: createdAt),
            recurrenceRaw: recurrence,
            hasBeenSynced: hasBeenSynced ?? false,
            dueDate: dueDate.map { Date(timeIntervalSince1970: $0) },
            completedAt: completedAt.map { Date(timeIntervalSince1970: $0) },
            aiEnhancedDescription: aiEnhancedDescription,
            appleSyncID: appleSyncID,
            categoryName: categoryName,
            habitCompletionDates: (habitCompletionDates ?? []).map { Date(timeIntervalSince1970: $0) },
            isInProgress: isInProgress ?? false,
            isFocusHabit: isFocusHabit ?? false,
            recurrenceAnchorDay: recurrenceAnchorDay
        )
    }
}

private struct CategoryDTO: Codable {
    var id: String
    var name: String
    var icon: String
    var colorName: String
    var isDefault: Bool
    var sortOrder: Int
    var isHabitCategory: Bool

    init(_ snapshot: CategoryBackupSnapshot) {
        id = snapshot.id.uuidString
        name = snapshot.name
        icon = snapshot.icon
        colorName = snapshot.colorName
        isDefault = snapshot.isDefault
        sortOrder = snapshot.sortOrder
        isHabitCategory = snapshot.isHabitCategory
    }

    var snapshot: CategoryBackupSnapshot? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return CategoryBackupSnapshot(
            id: uuid,
            name: name,
            icon: icon,
            colorName: colorName,
            isDefault: isDefault,
            sortOrder: sortOrder,
            isHabitCategory: isHabitCategory
        )
    }
}

private struct MemoryDTO: Codable {
    var id: String
    var content: String
    var kind: String
    var createdAt: Double
    var updatedAt: Double

    init(_ snapshot: MemoryBackupSnapshot) {
        id = snapshot.id.uuidString
        content = snapshot.content
        kind = snapshot.kind
        createdAt = snapshot.createdAt.timeIntervalSince1970
        updatedAt = snapshot.updatedAt.timeIntervalSince1970
    }

    var snapshot: MemoryBackupSnapshot? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return MemoryBackupSnapshot(
            id: uuid,
            content: content,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

// MARK: - Service

/// Writes and reads the app's local safety net: one JSON snapshot per day of
/// every reminder, category, and remembered fact, kept for
/// `retentionDays` days.
///
/// Backups are only useful if they can be read back, so this owns both halves:
/// `performDailyBackup` / `makeExportData` write, `loadBackup` reads, and
/// `BackupRestore` applies the result to the store as a non-destructive merge.
actor BackupService {
    static let shared = BackupService()

    /// Current write format. Readers accept 1 (bare reminder array) and 2.
    static let currentFormatVersion = 2

    /// How many daily snapshots to keep. Deliberately generous: the whole point
    /// is surviving a problem you didn't notice for a while, and the files are a
    /// few KB each.
    static let retentionDays = 30

    private let backupFolderName = "Backups"
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

    // MARK: Writing

    /// Writes today's snapshot if there isn't one yet, then prunes old files.
    /// Called on every launch and foreground from both platform roots, so it must
    /// stay idempotent and cheap.
    ///
    /// - Returns: `true` when a new file was written, `false` when today was
    ///   already covered.
    @discardableResult
    func performDailyBackup(
        reminders: [ReminderBackupSnapshot],
        categories: [CategoryBackupSnapshot],
        memories: [MemoryBackupSnapshot]
    ) async throws -> Bool {
        try ensureBackupDirectoryExists()
        guard let backupDir = backupDirectory else { throw BackupError.directoryNotFound }

        // Never overwrite a good snapshot with an empty one. An empty store early
        // in launch usually means CloudKit hasn't imported yet, and writing that
        // would turn the safety net into a record of nothing.
        guard !reminders.isEmpty else {
            try cleanOldBackups()
            return false
        }

        let todayURL = backupDir.appendingPathComponent(backupFileName(for: Date()))
        if fileManager.fileExists(atPath: todayURL.path) {
            try cleanOldBackups()
            return false
        }

        let data = try makeExportData(reminders: reminders, categories: categories, memories: memories)
        // Atomic write: a crash mid-write must not leave a truncated file where a
        // backup is supposed to be.
        try data.write(to: todayURL, options: .atomic)
        try cleanOldBackups()
        return true
    }

    /// The same bytes the daily backup writes, for "Export to File" — so anything
    /// the user exports can be restored later through the very same path.
    func makeExportData(
        reminders: [ReminderBackupSnapshot],
        categories: [CategoryBackupSnapshot],
        memories: [MemoryBackupSnapshot]
    ) throws -> Data {
        let envelope = BackupEnvelopeDTO(
            version: Self.currentFormatVersion,
            createdAt: Date().timeIntervalSince1970,
            reminders: reminders.map(ReminderDTO.init),
            categories: categories.map(CategoryDTO.init),
            memories: memories.map(MemoryDTO.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw BackupError.serializationFailed
        }
    }

    // MARK: Reading

    /// Decodes a backup file. Accepts both the v2 envelope and the v1 bare array.
    func loadBackup(at url: URL) throws -> BackupContents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.unreadable(error.localizedDescription)
        }
        return try Self.decode(data)
    }

    /// Pure decode, split out so it's testable without touching the filesystem.
    static func decode(_ data: Data) throws -> BackupContents {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(BackupEnvelopeDTO.self, from: data) {
            return BackupContents(
                formatVersion: envelope.version,
                createdAt: Date(timeIntervalSince1970: envelope.createdAt),
                reminders: envelope.reminders.compactMap(\.snapshot),
                categories: envelope.categories.compactMap(\.snapshot),
                memories: envelope.memories.compactMap(\.snapshot)
            )
        }

        // v1: a bare array of reminders, no categories or memories.
        if let rows = try? decoder.decode([ReminderDTO].self, from: data) {
            return BackupContents(
                formatVersion: 1,
                createdAt: nil,
                reminders: rows.compactMap(\.snapshot),
                categories: [],
                memories: []
            )
        }

        throw BackupError.unrecognizedFormat
    }

    // MARK: Listing / pruning

    func getBackupList() throws -> [(date: Date, url: URL, size: Int64)] {
        guard let backupDir = backupDirectory else { return [] }
        try ensureBackupDirectoryExists()

        let contents = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )

        var backups: [(date: Date, url: URL, size: Int64)] = []
        for fileURL in contents {
            guard fileURL.pathExtension == "json" else { continue }
            guard let fileDate = Self.date(fromBackupFileName: fileURL.deletingPathExtension().lastPathComponent) else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            let size = attributes?[.size] as? Int64 ?? 0
            backups.append((date: fileDate, url: fileURL, size: size))
        }
        return backups.sorted { $0.date > $1.date }
    }

    /// Date of the most recent snapshot, for the "last backed up" line in
    /// Settings — the reassurance that the safety net is actually running.
    func lastBackupDate() -> Date? {
        try? getBackupList().first?.date
    }

    private func cleanOldBackups() throws {
        guard let backupDir = backupDirectory else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -Self.retentionDays, to: Date()) else { return }

        for fileURL in contents {
            guard fileURL.pathExtension == "json" else { continue }
            guard let fileDate = Self.date(fromBackupFileName: fileURL.deletingPathExtension().lastPathComponent) else { continue }
            if fileDate < cutoffDate {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    // MARK: File naming (pure)

    private static let fileNamePrefix = "backup-"

    private nonisolated func backupFileName(for date: Date) -> String {
        Self.backupFileName(for: date)
    }

    static func backupFileName(for date: Date) -> String {
        "\(fileNamePrefix)\(dayFormatter.string(from: date)).json"
    }

    /// Parses `backup-YYYY-MM-DD` back to a date; nil for anything else in the
    /// folder (so a stray file is never mistaken for a snapshot, or deleted).
    static func date(fromBackupFileName name: String) -> Date? {
        guard name.hasPrefix(fileNamePrefix) else { return nil }
        return dayFormatter.date(from: String(name.dropFirst(fileNamePrefix.count)))
    }

    /// Fixed locale/calendar so file names don't shift with the user's region.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    enum BackupError: LocalizedError {
        case directoryNotFound
        case serializationFailed
        case unreadable(String)
        case unrecognizedFormat

        var errorDescription: String? {
            switch self {
            case .directoryNotFound:
                return "Could not find the backup folder."
            case .serializationFailed:
                return "Could not write the backup file."
            case .unreadable(let message):
                return "Could not read the backup file: \(message)"
            case .unrecognizedFormat:
                return "That file isn't a Gentle Nudge backup."
            }
        }
    }
}
