import Foundation
import EventKit

// MARK: - Value snapshots (cross the actor boundary)

/// A `Sendable` snapshot of ONE occurrence of a calendar event. Recurring events
/// (birthdays, weekly dinners) produce one snapshot per occurrence in the window,
/// each with its own `occurrenceKey`, so next year's birthday is a different
/// action item from this year's.
///
/// Every text field is user/third-party controlled (invites arrive from
/// strangers), so it is treated as untrusted data everywhere downstream — see
/// `PromptSafety` and the delimited `<events>` block in `CalendarTriageService`.
struct CalendarEventSnapshot: Sendable, Equatable, Identifiable {
    /// Stable identity for this occurrence: the event identifier (shared by all
    /// occurrences of a recurring series) plus the exact start instant. Seconds
    /// since 1970 is used rather than a formatted day so the key can't shift when
    /// the user travels across time zones.
    let occurrenceKey: String
    let title: String
    /// Truncated event notes, or "" — bounded so a pasted agenda can't dominate
    /// the prompt.
    let notes: String
    let location: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    /// True for events from the system Birthdays calendar (sourced from Contacts).
    let isBirthday: Bool
    let isRecurring: Bool
    /// Number of invitees, 0 for a solo/blocked-out event. A useful signal for
    /// "is this a dinner with people" vs "a reminder to myself".
    let attendeeCount: Int

    var id: String { occurrenceKey }

    /// Longest note text carried into the prompt.
    static let notesLimit = 300

    static func occurrenceKey(eventIdentifier: String?, calendarIdentifier: String, title: String, start: Date) -> String {
        let base = eventIdentifier?.isEmpty == false
            ? eventIdentifier!
            : "cal:\(calendarIdentifier)|t:\(title)"
        return "\(base)@\(Int(start.timeIntervalSince1970))"
    }
}

/// One calendar the user can include in / exclude from scanning.
struct CalendarInfo: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let isBirthday: Bool
}

// MARK: - Service

/// Read-only EventKit access to the user's *calendar events* (the sibling of
/// `AppleRemindersService`, which owns the Reminders side). Nothing here ever
/// writes to a calendar — the feature only reads events and proposes reminders
/// inside Gentle Nudge.
///
/// The event fetch is synchronous in EventKit and can be slow on a busy account,
/// which is exactly why this is an `actor`: it never runs on the main thread.
actor CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()

    private init() {}

    enum CalendarError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Gentle Nudge doesn't have permission to read your calendar. Grant access in Settings to pull in birthdays and events."
            }
        }
    }

    enum AuthorizationStatus: Sendable {
        case authorized
        case denied
        case notDetermined
    }

    nonisolated func checkAuthorizationStatus() -> AuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            // Write-only can add events but cannot read them, which is all this
            // feature does. Treat it as "not determined" so the full-access
            // prompt is still offered.
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Requests read access. The deployment targets (iOS 18.5 / macOS 15.5) are
    /// both past the iOS 17 / macOS 14 split, so the modern call is used directly.
    func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    /// Every calendar the user could scan, birthday calendars first (they're the
    /// highest-signal source and the one people look for).
    func availableCalendars() -> [CalendarInfo] {
        guard checkAuthorizationStatus() == .authorized else { return [] }
        return eventStore.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, isBirthday: $0.type == .birthday) }
            .sorted { lhs, rhs in
                if lhs.isBirthday != rhs.isBirthday { return lhs.isBirthday }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// Fetches every event occurrence from the start of today through
    /// `daysAhead` days later, inclusive.
    ///
    /// - Parameters:
    ///   - daysAhead: How far to look. 7 by default (the user-facing default).
    ///   - calendarIDs: Restrict to these calendar identifiers; `nil` or empty
    ///     means every calendar. Identifiers that no longer resolve are ignored
    ///     rather than treated as "scan nothing".
    ///   - limit: Hard cap on returned occurrences, soonest first, so a packed
    ///     work calendar can't blow up the prompt.
    func fetchUpcomingEvents(
        daysAhead: Int,
        calendarIDs: Set<String>?,
        referenceDate: Date = Date(),
        limit: Int = 60
    ) throws -> [CalendarEventSnapshot] {
        guard checkAuthorizationStatus() == .authorized else {
            throw CalendarError.accessDenied
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: referenceDate)
        // +1 so the final day is covered in full, not truncated at midnight.
        guard let end = calendar.date(byAdding: .day, value: max(1, daysAhead) + 1, to: start) else {
            return []
        }

        let allCalendars = eventStore.calendars(for: .event)
        let selected: [EKCalendar]?
        if let calendarIDs, !calendarIDs.isEmpty {
            let matches = allCalendars.filter { calendarIDs.contains($0.calendarIdentifier) }
            // An all-stale selection means "nothing matched", not "scan everything"
            // — but an empty predicate array would make EventKit search them all.
            if matches.isEmpty { return [] }
            selected = matches
        } else {
            selected = nil // every calendar
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selected)
        let events = eventStore.events(matching: predicate)

        var snapshots: [CalendarEventSnapshot] = []
        snapshots.reserveCapacity(min(events.count, limit))

        for event in events {
            guard !Self.shouldSkip(event) else { continue }
            guard let eventStart = event.startDate else { continue }
            let calendarIdentifier = event.calendar?.calendarIdentifier ?? ""
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            snapshots.append(
                CalendarEventSnapshot(
                    occurrenceKey: CalendarEventSnapshot.occurrenceKey(
                        eventIdentifier: event.eventIdentifier,
                        calendarIdentifier: calendarIdentifier,
                        title: title,
                        start: eventStart
                    ),
                    title: title,
                    notes: Self.truncatedNotes(event.notes),
                    location: (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    start: eventStart,
                    end: event.endDate ?? eventStart,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar?.title ?? "",
                    isBirthday: event.calendar?.type == .birthday,
                    isRecurring: event.hasRecurrenceRules,
                    attendeeCount: event.attendees?.count ?? 0
                )
            )
        }

        snapshots.sort { $0.start < $1.start }
        return Array(snapshots.prefix(limit))
    }

    // MARK: Filtering helpers (pure)

    /// Events that should never become action items: cancelled ones, and ones the
    /// user has already declined (they're not going, so there's nothing to
    /// prepare for).
    nonisolated static func shouldSkip(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        if let attendees = event.attendees,
           attendees.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) {
            return true
        }
        return false
    }

    nonisolated static func truncatedNotes(_ notes: String?) -> String {
        let trimmed = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > CalendarEventSnapshot.notesLimit else { return trimmed }
        return String(trimmed.prefix(CalendarEventSnapshot.notesLimit)) + "…"
    }
}
