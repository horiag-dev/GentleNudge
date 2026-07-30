import Foundation
import SwiftData

/// The one place that turns the live store into a daily snapshot, so both
/// platform roots (`ContentView` on iOS, `MacContentView` on the Mac) back up
/// identically. Before this existed only the iOS root called the backup service,
/// which meant a Mac-only day produced no snapshot at all.
///
/// Snapshotting happens on the main actor, then the file write is awaited on the
/// `BackupService` actor — the models themselves never cross a thread boundary.
@MainActor
enum DailyBackup {

    /// Writes today's snapshot if there isn't one yet. Safe and cheap to call on
    /// every launch and foreground; `BackupService` does the once-a-day gating and
    /// refuses to write an empty snapshot over a good one.
    static func run(context: ModelContext) async {
        let reminders = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        // Nothing to protect yet — and an empty fetch this early usually just
        // means CloudKit hasn't imported. Leave any existing snapshot alone.
        guard !reminders.isEmpty else { return }

        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let memories = (try? context.fetch(FetchDescriptor<UserMemory>())) ?? []

        let reminderSnapshots = reminders.map(ReminderBackupSnapshot.init)
        let categorySnapshots = categories.map(CategoryBackupSnapshot.init)
        let memorySnapshots = memories.map(MemoryBackupSnapshot.init)

        do {
            try await BackupService.shared.performDailyBackup(
                reminders: reminderSnapshots,
                categories: categorySnapshots,
                memories: memorySnapshots
            )
        } catch {
            print("Backup failed: \(error.localizedDescription)")
        }
    }
}
