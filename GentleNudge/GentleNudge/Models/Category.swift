import SwiftUI
import SwiftData

@Model
final class Category: Identifiable {
    var id: UUID
    var name: String
    var icon: String
    var colorName: String
    var isDefault: Bool
    var sortOrder: Int

    @Relationship(deleteRule: .nullify, inverse: \Reminder.category)
    var reminders: [Reminder]?

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        colorName: String,
        isDefault: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorName = colorName
        self.isDefault = isDefault
        self.sortOrder = sortOrder
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

    static var defaults: [Category] {
        [
            Category(name: "Habits", icon: "heart.circle.fill", colorName: "red", isDefault: true, sortOrder: 0),
            Category(name: "House", icon: "house.fill", colorName: "orange", isDefault: true, sortOrder: 1),
            Category(name: "Photos", icon: "photo.fill", colorName: "purple", isDefault: true, sortOrder: 2),
            Category(name: "Finance", icon: "dollarsign.circle.fill", colorName: "green", isDefault: true, sortOrder: 3),
            Category(name: "To Read", icon: "book.fill", colorName: "blue", isDefault: true, sortOrder: 4),
            Category(name: "Startup", icon: "lightbulb.fill", colorName: "yellow", isDefault: true, sortOrder: 5),
            Category(name: "Explore", icon: "safari.fill", colorName: "teal", isDefault: true, sortOrder: 6),
            Category(name: "GenAI", icon: "sparkles", colorName: "indigo", isDefault: true, sortOrder: 7),
            Category(name: "Misc", icon: "tray.fill", colorName: "mint", isDefault: true, sortOrder: 8),
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
}
