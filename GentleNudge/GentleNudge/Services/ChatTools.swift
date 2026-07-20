import Foundation

// MARK: - Tool input value types (cross the repository actor boundary)

struct CreateReminderInput: Sendable {
    let title: String
    let notes: String?
    let dueDate: String?
    let categoryID: String
    let recurrence: String
    let recurrenceAnchorDay: Int?
}

struct CreateCategoryInput: Sendable {
    let name: String
    let icon: String?
    let color: String?
}

/// Query/view over existing reminders. All fields optional except `status`;
/// ranges validated in the executor. Dates are `YYYY-MM-DD`.
struct FindRemindersInput: Sendable {
    let query: String?
    let categoryID: String?
    let status: String       // "active" | "completed" | "any"
    let dueFrom: String?
    let dueTo: String?
    let overdueOnly: Bool
}

/// A change to an existing reminder. `null` fields mean "leave unchanged" (strict
/// schemas force every field present); explicit clears use the boolean flag.
struct UpdateReminderInput: Sendable {
    let id: String
    let title: String?
    let notes: String?
    let dueDate: String?           // set the due date (YYYY-MM-DD)
    let clearDueDate: Bool         // remove the due date (and recurrence + anchor)
    let categoryID: String?
    let recurrence: String?        // change cadence
    let recurrenceAnchorDay: Int?
}

/// Reference to a single reminder by id, for complete/uncomplete/delete.
struct ReminderIDInput: Sendable {
    let id: String
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

    static let statusValues = ["active", "completed", "any"]

    static var all: [ToolDefinition] {
        [
            createReminder, createCategory,
            findReminders, updateReminder,
            completeReminder, uncompleteReminder, deleteReminder
        ]
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
                    "recurrence", "recurrence_anchor_day"
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

    static var findReminders: ToolDefinition {
        ToolDefinition(
            name: "find_reminders",
            description: """
            Search existing reminders. Use this to answer "show me / what's due \
            this week / what's overdue" questions, and ALWAYS before updating, \
            completing, or deleting a reminder — it returns the exact id each of \
            those tools needs. Returns up to 20 matching rows plus total_matches.
            """,
            strict: true,
            input_schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "query": nullableProp(
                        "string",
                        "Case-insensitive text to match against reminder titles and notes, or null for no text filter."
                    ),
                    "category_id": nullableProp(
                        "string",
                        "Limit to one category by its UUID (from the provided category list), or null for any category."
                    ),
                    "status": enumProp(
                        statusValues,
                        "Which reminders to include: 'active' (not completed), 'completed', or 'any'."
                    ),
                    "due_from": nullableProp(
                        "string",
                        "Earliest due date, inclusive, as YYYY-MM-DD, or null. Undated reminders are excluded when any date bound is set."
                    ),
                    "due_to": nullableProp(
                        "string",
                        "Latest due date, inclusive, as YYYY-MM-DD, or null. The whole day is included."
                    ),
                    "overdue_only": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, return only overdue reminders (past due and not completed).")
                    ])
                ]),
                "required": .array([
                    "query", "category_id", "status",
                    "due_from", "due_to", "overdue_only"
                ].map(JSONValue.string))
            ])
        )
    }

    static var updateReminder: ToolDefinition {
        ToolDefinition(
            name: "update_reminder",
            description: """
            Change fields of one existing reminder (found via find_reminders). Any \
            null field is left unchanged. To move a reminder to a different day, \
            set due_date. To remove the due date entirely set clear_due_date true \
            (this also clears recurrence). Do not set both due_date and \
            clear_due_date.
            """,
            strict: true,
            input_schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "id": stringProp("The UUID of the reminder to update, from find_reminders."),
                    "title": nullableProp("string", "New title, or null to leave unchanged."),
                    "notes": nullableProp(
                        "string",
                        "New notes (use an empty string to clear notes), or null to leave unchanged."
                    ),
                    "due_date": nullableProp(
                        "string",
                        "New due date as YYYY-MM-DD, or null to leave unchanged. For a recurring reminder this is the next occurrence."
                    ),
                    "clear_due_date": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, remove the due date (and any recurrence + anchor). Must not be combined with a non-null due_date.")
                    ]),
                    "category_id": nullableProp(
                        "string",
                        "New category UUID (from the provided list), or null to leave unchanged."
                    ),
                    "recurrence": nullableEnumProp(
                        recurrenceValues,
                        "New recurrence cadence, or null to leave unchanged. Setting anything other than 'none' requires the reminder to have a due date."
                    ),
                    "recurrence_anchor_day": nullableProp(
                        "integer",
                        "Day of month (1-31) for month-based recurrences, or null. The due date must fall on this day (clamped to the month length)."
                    )
                ]),
                "required": .array([
                    "id", "title", "notes", "due_date", "clear_due_date",
                    "category_id", "recurrence", "recurrence_anchor_day"
                ].map(JSONValue.string))
            ])
        )
    }

    static var completeReminder: ToolDefinition {
        ToolDefinition(
            name: "complete_reminder",
            description: """
            Mark one reminder complete (found via find_reminders). Recurring \
            reminders automatically spawn their next occurrence; habits are marked \
            done for today.
            """,
            strict: true,
            input_schema: idOnlySchema("The UUID of the reminder to complete.")
        )
    }

    static var uncompleteReminder: ToolDefinition {
        ToolDefinition(
            name: "uncomplete_reminder",
            description: """
            Mark one previously-completed reminder as not done again (found via \
            find_reminders). Undoes a completion, removing any spawned recurring \
            occurrence.
            """,
            strict: true,
            input_schema: idOnlySchema("The UUID of the reminder to mark not done.")
        )
    }

    static var deleteReminder: ToolDefinition {
        ToolDefinition(
            name: "delete_reminder",
            description: """
            Permanently delete one reminder (found via find_reminders). This asks \
            the user to confirm before anything is deleted. Only call it when the \
            user clearly wants a reminder removed, not merely completed.
            """,
            strict: true,
            input_schema: idOnlySchema("The UUID of the reminder to delete.")
        )
    }

    // MARK: Schema helpers

    private static func idOnlySchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "id": stringProp(description)
            ]),
            "required": .array([.string("id")])
        ])
    }

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

    /// A nullable enum: a string from `values` or `null`. Uses `anyOf` (which
    /// strict mode supports) so the enum constraint and the null branch stay
    /// cleanly separated — the safest strict-compatible spelling for "an enum or
    /// null" (see design §3.3 on nullable-union caveats).
    private static func nullableEnumProp(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "description": .string(description),
            "anyOf": .array([
                .object([
                    "type": .string("string"),
                    "enum": .array(values.map(JSONValue.string))
                ]),
                .object(["type": .string("null")])
            ])
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
