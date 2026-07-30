import Foundation
import SwiftData

// MARK: - Event kinds

/// The buckets the assistant sorts calendar events into. The kind is the axis the
/// auto-approve learning works on ("always add birthdays", "stop proposing
/// meetings"), so it is deliberately small and stable — raw strings, validated
/// through `normalized(_:)`, never an int (CloudKit + wire safety).
enum CalendarEventKind: String, CaseIterable, Identifiable, Sendable {
    case birthday
    case anniversary
    case dinner
    case travel
    case appointment
    case meeting
    case deadline
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .birthday: return "Birthdays"
        case .anniversary: return "Anniversaries"
        case .dinner: return "Dinners & social"
        case .travel: return "Travel"
        case .appointment: return "Appointments"
        case .meeting: return "Meetings"
        case .deadline: return "Deadlines"
        case .other: return "Everything else"
        }
    }

    var icon: String {
        switch self {
        case .birthday: return "gift.fill"
        case .anniversary: return "heart.fill"
        case .dinner: return "fork.knife"
        case .travel: return "airplane"
        case .appointment: return "stethoscope"
        case .meeting: return "person.2.fill"
        case .deadline: return "flag.fill"
        case .other: return "calendar"
        }
    }

    /// Kinds where the action is unambiguous the first time we see one, so the
    /// user's answer ("if certain like birthday etc, do it") is honored without
    /// waiting to learn: a birthday next week always means "get them something".
    /// Still gated on the model reporting high confidence.
    var isSelfEvident: Bool {
        switch self {
        case .birthday, .anniversary: return true
        default: return false
        }
    }

    static func normalized(_ raw: String) -> CalendarEventKind {
        CalendarEventKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }
}

/// How sure the assistant is that an event needs an action item.
enum CalendarConfidence: String, CaseIterable, Sendable {
    case high
    case medium
    case low

    static func normalized(_ raw: String) -> CalendarConfidence {
        CalendarConfidence(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .low
    }
}

/// Where a suggestion has ended up.
enum CalendarSuggestionState: String, CaseIterable, Sendable {
    /// Waiting for the user in the review queue.
    case pending
    /// Turned into a real reminder (by the user, or automatically).
    case accepted
    /// The user said no. Kept as a record so the same occurrence is never
    /// proposed twice, and so the learning counters have something to count.
    case dismissed
    /// The assistant looked at the event and there was nothing to do (or its kind
    /// is suppressed). Never shown to the user; recorded only so a daily re-scan
    /// of the same 7-day window doesn't pay to re-judge the same event all week.
    case noActionNeeded

    /// Exact match first, then case-insensitive. Lowercasing before the lookup —
    /// which the other two enums can get away with, since every one of their raw
    /// values is already lowercase — silently mapped the camelCase
    /// `noActionNeeded` to `.pending`, turning every "nothing to do here" record
    /// into a suggestion shown to the user.
    static func normalized(_ raw: String) -> CalendarSuggestionState {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = CalendarSuggestionState(rawValue: trimmed) { return exact }
        return allCases.first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame } ?? .pending
    }
}

// MARK: - CalendarSuggestion

/// One proposed action item derived from one calendar event occurrence.
///
/// Rows are kept after they're decided (accepted or dismissed): `occurrenceKey`
/// is the dedupe key that stops a re-scan from re-proposing something the user
/// already answered. Synced via CloudKit like every other model, so every stored
/// property carries a default and there are no non-optional relationships.
@Model
final class CalendarSuggestion: Identifiable {
    var id: UUID = UUID()

    // MARK: The source event (a snapshot — the calendar is never re-read to render)

    /// Stable identity of the event occurrence this came from. Unique in practice;
    /// `CalendarScanCoordinator` treats a duplicate as "already decided".
    var occurrenceKey: String = ""
    var eventTitle: String = ""
    var eventStart: Date = Date()
    var eventIsAllDay: Bool = false
    var calendarTitle: String = ""

    // MARK: The proposal

    var suggestedTitle: String = ""
    var suggestedNotes: String = ""
    /// When the action item should be due — typically a few days BEFORE the event
    /// (buy the gift before the birthday), which is the whole point of proposing.
    var suggestedDueDate: Date?
    /// Name of the category to file it under; resolved to a real `Category` at
    /// accept time (names are stable across devices, ids are not guaranteed to be
    /// resolvable at propose time).
    var suggestedCategoryName: String = ""

    /// Raw `CalendarEventKind`.
    var kindRaw: String = CalendarEventKind.other.rawValue
    /// Raw `CalendarConfidence`.
    var confidenceRaw: String = CalendarConfidence.low.rawValue
    /// One short sentence on why this needs an action item — shown on the card so
    /// an automatic add is never unexplained.
    var rationale: String = ""

    // MARK: Outcome

    /// Raw `CalendarSuggestionState`.
    var stateRaw: String = CalendarSuggestionState.pending.rawValue
    /// True when the app added this without asking (a self-evident kind, or a
    /// learned auto-approve rule). Drives the "Added automatically" badge.
    var wasAutoApproved: Bool = false
    /// The reminder this became, so an undo can find and remove it.
    var createdReminderID: UUID?

    var createdAt: Date = Date()
    var decidedAt: Date?

    init(
        id: UUID = UUID(),
        occurrenceKey: String,
        eventTitle: String,
        eventStart: Date,
        eventIsAllDay: Bool = false,
        calendarTitle: String = "",
        suggestedTitle: String,
        suggestedNotes: String = "",
        suggestedDueDate: Date? = nil,
        suggestedCategoryName: String = "",
        kind: CalendarEventKind = .other,
        confidence: CalendarConfidence = .low,
        rationale: String = "",
        state: CalendarSuggestionState = .pending,
        wasAutoApproved: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey
        self.eventTitle = eventTitle
        self.eventStart = eventStart
        self.eventIsAllDay = eventIsAllDay
        self.calendarTitle = calendarTitle
        self.suggestedTitle = suggestedTitle
        self.suggestedNotes = suggestedNotes
        self.suggestedDueDate = suggestedDueDate
        self.suggestedCategoryName = suggestedCategoryName
        self.kindRaw = kind.rawValue
        self.confidenceRaw = confidence.rawValue
        self.rationale = rationale
        self.stateRaw = state.rawValue
        self.wasAutoApproved = wasAutoApproved
        self.createdAt = createdAt
        self.decidedAt = state == .pending ? nil : createdAt
    }

    var kind: CalendarEventKind {
        get { CalendarEventKind.normalized(kindRaw) }
        set { kindRaw = newValue.rawValue }
    }

    var confidence: CalendarConfidence {
        get { CalendarConfidence.normalized(confidenceRaw) }
        set { confidenceRaw = newValue.rawValue }
    }

    var state: CalendarSuggestionState {
        get { CalendarSuggestionState.normalized(stateRaw) }
        set { stateRaw = newValue.rawValue }
    }

    var isPending: Bool { state == .pending }
}

// MARK: - CalendarAutoRule

/// What the app has learned about one event kind: how often the user accepted or
/// dismissed its suggestions, and whether it should now skip the review queue.
///
/// One row per `CalendarEventKind`. This is the "learn what to auto approve"
/// mechanism, and it is deliberately a transparent counter rather than anything
/// implicit — the Settings screen shows each kind, its tally, and lets the user
/// force the answer either way.
@Model
final class CalendarAutoRule: Identifiable {
    var id: UUID = UUID()
    /// Raw `CalendarEventKind`; one row per kind.
    var kindRaw: String = CalendarEventKind.other.rawValue

    var acceptCount: Int = 0
    var dismissCount: Int = 0

    /// Add suggestions of this kind straight to the reminder list. Set by the
    /// learning thresholds below, by a self-evident kind's seed, or by the user
    /// flipping the switch in Settings.
    var autoApprove: Bool = false
    /// Stop proposing this kind at all. Reached by repeatedly dismissing, or set
    /// by hand — the escape hatch for a noisy work calendar.
    var suppressed: Bool = false
    /// True once the user has set `autoApprove`/`suppressed` by hand, which pins
    /// the rule: the counters keep updating but no longer flip the switches back.
    var userOverridden: Bool = false

    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        kind: CalendarEventKind,
        acceptCount: Int = 0,
        dismissCount: Int = 0,
        autoApprove: Bool = false,
        suppressed: Bool = false,
        userOverridden: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.acceptCount = acceptCount
        self.dismissCount = dismissCount
        self.autoApprove = autoApprove
        self.suppressed = suppressed
        self.userOverridden = userOverridden
        self.updatedAt = updatedAt
    }

    var kind: CalendarEventKind {
        get { CalendarEventKind.normalized(kindRaw) }
        set { kindRaw = newValue.rawValue }
    }

    /// Net accepts after this many, a kind starts adding itself.
    static let autoApproveThreshold = 3
    /// Net dismissals after this many, a kind stops being proposed.
    static let suppressThreshold = 3

    /// Records one decision and re-derives the switches. Returns whether either
    /// switch changed, so the caller can tell the user "Gentle Nudge will add
    /// birthdays automatically from now on".
    ///
    /// A hand-set rule (`userOverridden`) keeps counting but never has its
    /// switches moved back by the thresholds — an explicit choice outranks a
    /// learned one.
    @discardableResult
    func record(accepted: Bool) -> Bool {
        if accepted { acceptCount += 1 } else { dismissCount += 1 }
        updatedAt = Date()
        return rederiveFromCounts()
    }

    /// Re-derives `autoApprove` / `suppressed` from the tallies alone, and reports
    /// whether either changed. A hand-set rule is left exactly as the user set it.
    /// Also the way back from an override: clear `userOverridden`, then call this.
    @discardableResult
    func rederiveFromCounts() -> Bool {
        guard !userOverridden else { return false }
        let net = acceptCount - dismissCount
        let shouldAutoApprove = net >= Self.autoApproveThreshold
        // A kind that is self-evident (birthdays) has to be actively rejected
        // enough times to stop adding itself; it doesn't need to be earned first.
        let shouldSuppress = -net >= Self.suppressThreshold
        let changed = shouldAutoApprove != autoApprove || shouldSuppress != suppressed
        autoApprove = shouldAutoApprove || (kind.isSelfEvident && !shouldSuppress)
        suppressed = shouldSuppress
        return changed
    }

    /// Fetches the rule for `kind`, creating (and inserting) it on first use.
    /// Self-evident kinds are seeded with `autoApprove` already on so the very
    /// first birthday is added rather than queued.
    static func rule(for kind: CalendarEventKind, in context: ModelContext) -> CalendarAutoRule {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<CalendarAutoRule>(predicate: #Predicate { $0.kindRaw == raw })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = CalendarAutoRule(kind: kind, autoApprove: kind.isSelfEvident)
        context.insert(created)
        return created
    }
}
