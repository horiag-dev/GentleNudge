import Foundation
import SwiftData

/// Applies a decoded backup to the live store.
///
/// **Non-destructive by design.** A restore only ever *adds* what's missing:
/// anything already in the store — matched on the stable `id` — is left exactly
/// as it is, and nothing is ever deleted. That makes restoring safe to try when
/// you're not sure what went wrong, which is the moment people actually reach for
/// a backup. It also makes it idempotent: restoring the same file twice adds
/// nothing the second time.
///
/// Runs on the main actor because it writes through the container's main context,
/// keeping every `@Query` in the UI live (the same choice `CalendarScanCoordinator`
/// makes).
@MainActor
enum BackupRestore {

    /// What a restore did, so the UI can report it precisely rather than saying
    /// "done" and leaving the user to guess.
    struct Summary: Equatable, Sendable {
        var remindersAdded = 0
        var remindersAlreadyPresent = 0
        var categoriesAdded = 0
        var memoriesAdded = 0
        var memoriesAlreadyPresent = 0

        var addedNothing: Bool {
            remindersAdded == 0 && categoriesAdded == 0 && memoriesAdded == 0
        }

        var message: String {
            if addedNothing {
                let seen = remindersAlreadyPresent + memoriesAlreadyPresent
                return seen > 0
                    ? "Nothing to restore — all \(seen) item\(seen == 1 ? "" : "s") in that backup are already here."
                    : "That backup was empty."
            }
            var parts: [String] = []
            if remindersAdded > 0 { parts.append("\(remindersAdded) reminder\(remindersAdded == 1 ? "" : "s")") }
            if categoriesAdded > 0 { parts.append("\(categoriesAdded) categor\(categoriesAdded == 1 ? "y" : "ies")") }
            if memoriesAdded > 0 { parts.append("\(memoriesAdded) memor\(memoriesAdded == 1 ? "y" : "ies")") }
            var text = "Restored \(parts.joined(separator: ", "))."
            if remindersAlreadyPresent > 0 {
                text += " \(remindersAlreadyPresent) were already here and were left untouched."
            }
            return text
        }
    }

    enum RestoreError: LocalizedError {
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let message):
                return "Could not save the restored items: \(message)"
            }
        }
    }

    /// Merges `contents` into `context`. Throws only if the save fails, in which
    /// case the context is rolled back and the store is untouched.
    @discardableResult
    static func apply(_ contents: BackupContents, to context: ModelContext) throws -> Summary {
        var summary = Summary()

        // MARK: Categories first — reminders resolve their category by name.

        let existingCategories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        // Name is the join key (ids differ across devices/reinstalls, names are
        // what the user actually recognizes), matched case-insensitively so a
        // "misc" backup doesn't create a second "Misc".
        var categoriesByName: [String: Category] = [:]
        for category in existingCategories {
            categoriesByName[category.name.lowercased()] = category
        }

        for snapshot in contents.categories {
            let key = snapshot.name.lowercased()
            guard categoriesByName[key] == nil else { continue }
            let category = Category(
                id: snapshot.id,
                name: snapshot.name,
                icon: snapshot.icon,
                colorName: snapshot.colorName,
                isDefault: snapshot.isDefault,
                sortOrder: snapshot.sortOrder,
                isHabitCategory: snapshot.isHabitCategory
            )
            context.insert(category)
            categoriesByName[key] = category
            summary.categoriesAdded += 1
        }

        // MARK: Reminders

        let existingReminderIDs = Set(((try? context.fetch(FetchDescriptor<Reminder>())) ?? []).map(\.id))

        for snapshot in contents.reminders {
            guard !existingReminderIDs.contains(snapshot.id) else {
                summary.remindersAlreadyPresent += 1
                continue
            }

            // A v1 backup carries only the category name. If it names a category
            // that no longer exists, recreate a minimal one rather than dropping
            // the reminder's grouping.
            var category: Category?
            if let name = snapshot.categoryName, !name.isEmpty {
                let key = name.lowercased()
                if let existing = categoriesByName[key] {
                    category = existing
                } else {
                    let created = Category(
                        name: name,
                        icon: "folder.fill",
                        colorName: "gray",
                        sortOrder: (categoriesByName.count) + 100
                    )
                    context.insert(created)
                    categoriesByName[key] = created
                    category = created
                    summary.categoriesAdded += 1
                }
            }

            let reminder = Reminder(
                id: snapshot.id,
                title: snapshot.title,
                notes: snapshot.notes,
                dueDate: snapshot.dueDate,
                priority: ReminderPriority(rawValue: snapshot.priorityRaw) ?? .normal,
                isCompleted: snapshot.isCompleted,
                isInProgress: snapshot.isInProgress,
                isFocusHabit: snapshot.isFocusHabit,
                category: category,
                recurrence: RecurrenceType(rawValue: snapshot.recurrenceRaw) ?? .none
            )
            // Fields the initializer stamps with "now" or doesn't take at all —
            // restored explicitly so history survives the round trip.
            reminder.createdAt = snapshot.createdAt
            reminder.completedAt = snapshot.completedAt
            reminder.aiEnhancedDescription = snapshot.aiEnhancedDescription
            reminder.appleSyncID = snapshot.appleSyncID
            reminder.hasBeenSynced = snapshot.hasBeenSynced
            reminder.habitCompletionDates = snapshot.habitCompletionDates
            reminder.recurrenceAnchorDay = snapshot.recurrenceAnchorDay

            context.insert(reminder)
            summary.remindersAdded += 1
        }

        // MARK: Memories

        let existingMemoryIDs = Set(((try? context.fetch(FetchDescriptor<UserMemory>())) ?? []).map(\.id))
        for snapshot in contents.memories {
            guard !existingMemoryIDs.contains(snapshot.id) else {
                summary.memoriesAlreadyPresent += 1
                continue
            }
            context.insert(
                UserMemory(
                    id: snapshot.id,
                    content: snapshot.content,
                    kind: UserMemory.normalizedKind(snapshot.kind),
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt
                )
            )
            summary.memoriesAdded += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw RestoreError.saveFailed(error.localizedDescription)
        }

        return summary
    }
}
