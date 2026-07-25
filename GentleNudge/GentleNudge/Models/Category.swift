import SwiftUI
import SwiftData

@Model
final class Category: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "folder.fill"
    var colorName: String = "gray"
    var isDefault: Bool = false
    var sortOrder: Int = 0

    /// Stable marker that identifies the habits category, independent of its name.
    /// Habit identity (`Reminder.isHabit`) keys off this rather than a fragile
    /// `name == "Habits"` check. Has a default value for CloudKit compatibility.
    var isHabitCategory: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \Reminder.category)
    var reminders: [Reminder]?

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        colorName: String,
        isDefault: Bool = false,
        sortOrder: Int = 0,
        isHabitCategory: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorName = colorName
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.isHabitCategory = isHabitCategory
    }

    var color: Color {
        switch colorName {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "mint": return .mint
        default: return .gray
        }
    }

    /// Foreground that stays legible when this category's color is the FILL
    /// behind text or icons: near-black on light hues (yellow, mint, …),
    /// white on dark ones. White-on-yellow (the default "Today" category)
    /// fails contrast badly, which is what this exists to prevent.
    var contrastingForeground: Color {
        Self.contrastingForeground(forColorName: colorName)
    }

    /// Perceived brightness (ITU-R BT.601: 0.299 R + 0.587 G + 0.114 B) of
    /// each palette color, precomputed from the system colors' light-mode
    /// sRGB values. The palette splits cleanly around 0.52: hues above the
    /// threshold are too light for white content, so they take near-black.
    static func contrastingForeground(forColorName name: String) -> Color {
        let brightness: [String: Double] = [
            "red": 0.46, "orange": 0.64, "yellow": 0.77, "green": 0.56,
            "blue": 0.40, "purple": 0.49, "pink": 0.44, "teal": 0.55,
            "indigo": 0.40, "mint": 0.54, "gray": 0.56,
        ]
        return (brightness[name] ?? 0.56) > 0.52 ? Color.black.opacity(0.85) : .white
    }

    static var defaults: [Category] {
        [
            Category(name: "Habits", icon: "heart.circle.fill", colorName: "red", isDefault: true, sortOrder: 0, isHabitCategory: true),
            Category(name: "Today", icon: "sun.max.fill", colorName: "yellow", isDefault: true, sortOrder: 1),
            Category(name: "House", icon: "house.fill", colorName: "green", isDefault: true, sortOrder: 2),
            Category(name: "Photos", icon: "photo.fill", colorName: "purple", isDefault: true, sortOrder: 3),
            Category(name: "Finance", icon: "dollarsign.circle.fill", colorName: "teal", isDefault: true, sortOrder: 4),
            Category(name: "To Read", icon: "book.fill", colorName: "blue", isDefault: true, sortOrder: 5),
            Category(name: "Startup", icon: "lightbulb.fill", colorName: "orange", isDefault: true, sortOrder: 6),
            Category(name: "Explore", icon: "safari.fill", colorName: "indigo", isDefault: true, sortOrder: 7),
            Category(name: "GenAI", icon: "sparkles", colorName: "pink", isDefault: true, sortOrder: 8),
            Category(name: "Misc", icon: "tray.fill", colorName: "mint", isDefault: true, sortOrder: 9),
        ]
    }

    static var availableIcons: [String] {
        [
            "house.fill", "briefcase.fill", "cart.fill", "heart.fill",
            "star.fill", "flag.fill", "bookmark.fill", "tag.fill",
            "folder.fill", "tray.fill", "doc.fill", "book.fill",
            "graduationcap.fill", "pencil", "paintbrush.fill", "wrench.fill",
            "gearshape.fill", "person.fill", "person.2.fill", "figure.walk",
            "car.fill", "airplane", "gift.fill", "creditcard.fill",
            "banknote.fill", "phone.fill", "envelope.fill", "calendar",
            "clock.fill", "alarm.fill", "stopwatch.fill", "timer",
            "camera.fill", "photo.fill", "film.fill", "tv.fill",
            "gamecontroller.fill", "headphones", "music.note", "guitars.fill",
            "fork.knife", "cup.and.saucer.fill", "leaf.fill", "pawprint.fill",
            "cross.fill", "pills.fill", "bandage.fill", "stethoscope",
            "dumbbell.fill", "sportscourt.fill", "trophy.fill", "medal.fill",
            "exclamationmark.circle.fill", "checkmark.circle.fill", "xmark.circle.fill", "questionmark.circle.fill"
        ]
    }

    static var availableColors: [String] {
        ["red", "orange", "yellow", "green", "blue", "purple", "pink", "teal", "indigo", "mint"]
    }

    /// One-time backfill for stores created before `isHabitCategory` existed:
    /// stamps the marker onto the pre-existing "Habits" category so habit identity
    /// no longer depends on a name match. Idempotent and safe to call on every
    /// launch — a no-op when the Habits category is absent or already marked.
    @MainActor
    static func backfillHabitMarker(in context: ModelContext) {
        var descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Habits" }
        )
        descriptor.fetchLimit = 1
        guard let habits = try? context.fetch(descriptor).first,
              !habits.isHabitCategory else { return }
        habits.isHabitCategory = true
        try? context.save()
    }

    /// Merges duplicate categories (same trimmed, case-insensitive name), which
    /// appear when two devices both seed the defaults before CloudKit finishes
    /// its first import. For each duplicated name exactly ONE survivor is kept —
    /// preferring the `isDefault` one, then the `isHabitCategory` one, then the
    /// earliest by `sortOrder` (id as the final tiebreak, so every device
    /// independently picks the SAME survivor and the merge converges). Every
    /// reminder on a losing duplicate is reparented onto the survivor BEFORE the
    /// duplicate is deleted, so no reminder ever loses its category; the habit
    /// marker is preserved on the survivor if any duplicate carried it.
    /// Idempotent and safe to run on every launch — a no-op when there are no
    /// duplicates (nothing is written or saved).
    @MainActor
    @discardableResult
    static func cleanDuplicates(in context: ModelContext) -> Int {
        guard let categories = try? context.fetch(FetchDescriptor<Category>()) else { return 0 }

        var groups: [String: [Category]] = [:]
        for category in categories {
            let key = category.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(category)
        }

        var removedCount = 0
        for (_, duplicates) in groups where duplicates.count > 1 {
            let ranked = duplicates.sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                if a.isHabitCategory != b.isHabitCategory { return a.isHabitCategory }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.id.uuidString < b.id.uuidString
            }
            let survivor = ranked[0]
            // Keep habit identity working even if only a losing copy was marked.
            if !survivor.isHabitCategory, duplicates.contains(where: { $0.isHabitCategory }) {
                survivor.isHabitCategory = true
            }
            for loser in ranked.dropFirst() {
                // Copy the relationship before mutating it: reassigning
                // `reminder.category` edits `loser.reminders` underneath us.
                let orphans = loser.reminders ?? []
                for reminder in orphans {
                    reminder.category = survivor
                }
                context.delete(loser)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            try? context.save()
        }
        return removedCount
    }
}
