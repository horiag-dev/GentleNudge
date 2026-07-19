import Foundation

// MARK: - Tool input value types (cross the repository actor boundary)

struct CreateReminderInput: Sendable {
    let title: String
    let notes: String?
    let dueDate: String?
    let categoryID: String
    let priority: String
    let recurrence: String
    let recurrenceAnchorDay: Int?
}

struct CreateCategoryInput: Sendable {
    let name: String
    let icon: String?
    let color: String?
}

// MARK: - Tool schema definitions (strict mode)

/// Strict-mode tool schemas for the chat assistant. Every tool sets
/// `strict: true`, `additionalProperties: false`, lists *all* properties in
/// `required`, and expresses optionality with nullable-type unions
/// (`{"type": ["string","null"]}`). No `minimum`/`maximum`/`minLength`/`maxLength`
/// — strict mode rejects those; ranges (e.g. the 1–31 anchor) are enforced in the
/// executor. Recurrence crosses the wire as enum *strings*, never raw ints.
enum ChatTools {
    static let recurrenceValues = [
        "none", "daily", "weekdays", "weekends", "weekly",
        "biweekly", "monthly", "quarterly", "semiannually", "yearly"
    ]

    static var all: [ToolDefinition] {
        [createReminder, createCategory]
    }

    static var createReminder: ToolDefinition {
        ToolDefinition(
            name: "create_reminder",
            description: """
            Create a single reminder. Call this once per distinct task the user \
            mentions. Resolve any relative date to a concrete YYYY-MM-DD first. \
            For recurring reminders, due_date is the first occurrence.
            """,
            strict: true,
            input_schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "title": stringProp("Short, action-oriented reminder title."),
                    "notes": nullableProp("string", "Optional extra detail, or null."),
                    "due_date": nullableProp(
                        "string",
                        "First occurrence date as YYYY-MM-DD, or null for an undated reminder. Required (non-null) for any recurring reminder."
                    ),
                    "category_id": stringProp(
                        "The UUID of an existing category, taken from the category list provided in the system context."
                    ),
                    "priority": enumProp(["normal", "urgent"], "Reminder priority."),
                    "recurrence": enumProp(
                        recurrenceValues,
                        "Recurrence cadence. Use 'none' for a one-off reminder. Only these cadences are supported."
                    ),
                    "recurrence_anchor_day": nullableProp(
                        "integer",
                        "Day of month (1-31) for month-based recurrences (monthly, quarterly, semiannually, yearly). Null for other cadences. The first due_date must fall on this day (clamped to the month length)."
                    )
                ]),
                "required": .array([
                    "title", "notes", "due_date", "category_id",
                    "priority", "recurrence", "recurrence_anchor_day"
                ].map(JSONValue.string))
            ])
        )
    }

    static var createCategory: ToolDefinition {
        ToolDefinition(
            name: "create_category",
            description: """
            Propose creating a new category. This asks the user for confirmation \
            before anything is created. Only call this when no existing category \
            reasonably fits.
            """,
            strict: true,
            input_schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "name": stringProp("The proposed category name."),
                    "icon": nullableProp("string", "Optional SF Symbol name hint, or null."),
                    "color": nullableProp(
                        "string",
                        "Optional color hint (red, orange, yellow, green, blue, purple, pink, teal, indigo, mint), or null."
                    )
                ]),
                "required": .array(["name", "icon", "color"].map(JSONValue.string))
            ])
        )
    }

    // MARK: Schema helpers

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func nullableProp(_ type: String, _ description: String) -> JSONValue {
        .object([
            "type": .array([.string(type), .string("null")]),
            "description": .string(description)
        ])
    }

    private static func enumProp(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
            "description": .string(description)
        ])
    }
}

// MARK: - Recurrence string mapping

extension RecurrenceType {
    /// Maps the wire enum string to a `RecurrenceType`. Never uses raw ints.
    static func fromToolValue(_ value: String) -> RecurrenceType? {
        switch value {
        case "none": return RecurrenceType.none
        case "daily": return .daily
        case "weekdays": return .weekdays
        case "weekends": return .weekends
        case "weekly": return .weekly
        case "biweekly": return .biweekly
        case "monthly": return .monthly
        case "quarterly": return .quarterly
        case "semiannually": return .semiannually
        case "yearly": return .yearly
        default: return nil
        }
    }

    /// Month-anchored cadences whose successors depend on `recurrenceAnchorDay`.
    var isMonthBased: Bool {
        switch self {
        case .monthly, .quarterly, .semiannually, .yearly: return true
        default: return false
        }
    }
}
