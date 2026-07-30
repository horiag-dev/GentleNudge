import Foundation
import SwiftData
import Observation

/// Runs one calendar → action-item pass and owns everything the user can do with
/// the result.
///
/// The pipeline, in order:
/// 1. Read the next `Constants.calendarDaysAhead` days of events (off the main
///    thread, inside `CalendarService`).
/// 2. Drop every occurrence already decided — the dedupe that makes a daily scan
///    cheap and stops a re-scan re-asking about the same dinner all week.
/// 3. Ask Claude which of the rest need an action item (`CalendarTriageService`),
///    falling back to the offline birthday heuristic on any failure.
/// 4. For each proposal, consult the learned `CalendarAutoRule` for its kind:
///    **add it outright** when the kind auto-approves and confidence is high,
///    **drop it** when the kind is suppressed, otherwise **queue it for review**.
///
/// SwiftData writes go through the container's main context (small, and it keeps
/// every `@Query` in the UI live); the slow work — EventKit and the network — is
/// awaited on its own actor.
@MainActor
@Observable
final class CalendarScanCoordinator {

    enum ScanState: Equatable {
        case idle
        case scanning
        /// Permission is missing or was refused; the UI offers a Grant button.
        case needsPermission
        case failed(String)
    }

    /// What one scan did, for the Settings summary line.
    struct ScanOutcome: Equatable, Sendable {
        var added: Int = 0
        var queued: Int = 0
        var examined: Int = 0
        var skippedForSize: Int = 0
        var usedFallback: Bool = false

        var summary: String {
            if examined == 0 { return "No new events to look at." }
            var parts: [String] = []
            if added > 0 { parts.append("added \(added)") }
            if queued > 0 { parts.append("\(queued) to review") }
            if parts.isEmpty { parts.append("nothing needed doing") }
            var text = "Checked \(examined) event\(examined == 1 ? "" : "s"): \(parts.joined(separator: ", "))."
            if skippedForSize > 0 {
                text += " \(skippedForSize) event\(skippedForSize == 1 ? "" : "s") beyond the per-scan limit weren't checked."
            }
            if usedFallback {
                text += " (Offline mode — only birthdays and anniversaries were checked.)"
            }
            return text
        }
    }

    private(set) var state: ScanState = .idle
    private(set) var lastScanAt: Date?
    private(set) var lastOutcome: ScanOutcome?
    /// Set when a decision changed a learned rule, so the UI can say so once
    /// ("Birthdays will be added automatically from now on"). Read-and-clear.
    var learningNotice: String?

    private let container: ModelContainer
    private let calendarService: CalendarService
    private let triageService: CalendarTriageService
    private let calendar: Calendar

    /// Suggestion rows for events older than this are pruned each scan, so the
    /// dedupe ledger stays bounded (and keeps syncing cheap).
    private static let historyRetentionDays = 60

    init(
        modelContainer: ModelContainer,
        calendarService: CalendarService = .shared,
        triageService: CalendarTriageService = CalendarTriageService()
    ) {
        self.container = modelContainer
        self.calendarService = calendarService
        self.triageService = triageService
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
    }

    private var context: ModelContext { container.mainContext }

    // MARK: - Permission

    var authorizationStatus: CalendarService.AuthorizationStatus {
        calendarService.checkAuthorizationStatus()
    }

    /// Asks for calendar access and, when granted, immediately runs a scan so the
    /// user sees the result of saying yes.
    func requestAccessAndScan() async {
        do {
            let granted = try await calendarService.requestAccess()
            guard granted else {
                state = .needsPermission
                return
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        await scan()
    }

    // MARK: - Scanning

    /// The once-a-day entry point, called when a Today view appears or the app
    /// foregrounds. Cheap and safe to call repeatedly.
    func scanIfNeeded() async {
        guard Constants.isCalendarScanEnabled else { return }
        guard state != .scanning else { return }
        guard UserDefaults.standard.string(forKey: Constants.DefaultsKeys.calendarLastScanDay) != Self.dayKey(for: Date(), calendar: calendar) else { return }
        await scan()
    }

    /// Runs a full pass unconditionally — this is what "Scan now" calls. The
    /// once-a-day gate lives in `scanIfNeeded`; the enabled flag and permission
    /// are still enforced here.
    func scan() async {
        guard Constants.isCalendarScanEnabled else { return }
        guard authorizationStatus == .authorized else {
            state = .needsPermission
            return
        }
        guard state != .scanning else { return }

        state = .scanning
        let now = Date()

        // 1. Read the window.
        let events: [CalendarEventSnapshot]
        do {
            events = try await calendarService.fetchUpcomingEvents(
                daysAhead: Constants.calendarDaysAhead,
                calendarIDs: Constants.calendarSelectedIDs,
                referenceDate: now
            )
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        pruneOldSuggestions(referenceDate: now)

        // 2. Drop occurrences that already have a verdict.
        let decidedKeys = allDecidedKeys()
        let fresh = events.filter { !decidedKeys.contains($0.occurrenceKey) }
        guard !fresh.isEmpty else {
            save() // persist the prune above
            finish(outcome: ScanOutcome(examined: 0), at: now)
            return
        }

        // 3. Ask Claude.
        let result = await triageService.triage(
            events: fresh,
            categoryNames: assignableCategoryNames(),
            existingReminderTitles: activeReminderTitles(),
            referenceDate: now,
            calendar: calendar,
            timeZone: calendar.timeZone
        )

        // 4. Route each decision.
        var outcome = ScanOutcome(
            examined: fresh.count,
            skippedForSize: result.skippedForSize,
            usedFallback: result.usedFallback
        )
        let eventsByKey = Dictionary(uniqueKeysWithValues: fresh.map { ($0.occurrenceKey, $0) })
        var handled: Set<String> = []

        for proposal in result.proposals {
            guard let event = eventsByKey[proposal.occurrenceKey] else { continue }
            handled.insert(proposal.occurrenceKey)

            guard proposal.needsAction else {
                insertNoActionRecord(for: event, kind: proposal.kind)
                continue
            }

            let rule = CalendarAutoRule.rule(for: proposal.kind, in: context)
            if rule.suppressed {
                // The user has told us to stop proposing this kind. Record a
                // verdict anyway so we never pay to judge this occurrence again.
                insertNoActionRecord(for: event, kind: proposal.kind)
                continue
            }

            // "If certain, just do it": an auto-approving kind still has to come
            // with high confidence before anything lands unasked.
            let autoApprove = rule.autoApprove && proposal.confidence == .high
            let suggestion = makeSuggestion(
                from: proposal,
                event: event,
                state: autoApprove ? .accepted : .pending,
                wasAutoApproved: autoApprove
            )
            context.insert(suggestion)

            if autoApprove {
                let reminder = createReminder(from: suggestion)
                suggestion.createdReminderID = reminder?.id
                suggestion.decidedAt = now
                outcome.added += 1
            } else {
                outcome.queued += 1
            }
        }

        // Events the model silently skipped (a short reply, or an offline pass
        // that only looked at birthdays) stay undecided on purpose: the next scan
        // gets another try rather than recording a verdict nobody made. The
        // offline path is the exception — it examined and rejected them.
        if result.usedFallback {
            for event in fresh where !handled.contains(event.occurrenceKey) {
                insertNoActionRecord(for: event, kind: .other)
            }
        }

        save()
        finish(outcome: outcome, at: now)
    }

    private func finish(outcome: ScanOutcome, at date: Date) {
        lastOutcome = outcome
        lastScanAt = date
        // Never clobber a failure recorded during the pass (e.g. a failed save).
        if state == .scanning { state = .idle }
        UserDefaults.standard.set(Self.dayKey(for: date, calendar: calendar), forKey: Constants.DefaultsKeys.calendarLastScanDay)
    }

    // MARK: - User decisions (and the learning they drive)

    /// Accepts a queued suggestion: creates the reminder and teaches the rule for
    /// its kind that this was wanted.
    func accept(_ suggestion: CalendarSuggestion) {
        guard suggestion.isPending else { return }
        let reminder = createReminder(from: suggestion)
        suggestion.createdReminderID = reminder?.id
        suggestion.state = .accepted
        suggestion.decidedAt = Date()
        recordDecision(kind: suggestion.kind, accepted: true)
        save()
    }

    /// Declines a queued suggestion. Nothing is created, and the rule for its kind
    /// learns that this wasn't wanted.
    func dismiss(_ suggestion: CalendarSuggestion) {
        guard suggestion.isPending else { return }
        suggestion.state = .dismissed
        suggestion.decidedAt = Date()
        recordDecision(kind: suggestion.kind, accepted: false)
        save()
    }

    /// Undoes an automatic add: deletes the reminder it created and counts as a
    /// rejection, so a kind that starts adding the wrong things can be taught back
    /// down without a trip to Settings.
    func undoAutoAdd(_ suggestion: CalendarSuggestion) {
        guard suggestion.state == .accepted else { return }
        if let reminderID = suggestion.createdReminderID {
            var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == reminderID })
            descriptor.fetchLimit = 1
            if let reminder = try? context.fetch(descriptor).first {
                context.delete(reminder)
            }
        }
        suggestion.createdReminderID = nil
        suggestion.state = .dismissed
        suggestion.decidedAt = Date()
        recordDecision(kind: suggestion.kind, accepted: false)
        save()
    }

    /// Explicit user override — "always add these" / "stop proposing these". Pins
    /// the rule so the learned thresholds stop moving it.
    func setRule(kind: CalendarEventKind, autoApprove: Bool, suppressed: Bool) {
        let rule = CalendarAutoRule.rule(for: kind, in: context)
        rule.autoApprove = autoApprove
        rule.suppressed = suppressed
        rule.userOverridden = true
        rule.updatedAt = Date()
        save()
    }

    /// Hands a kind back to the learning thresholds.
    func clearOverride(kind: CalendarEventKind) {
        let rule = CalendarAutoRule.rule(for: kind, in: context)
        rule.userOverridden = false
        rule.rederiveFromCounts()
        rule.updatedAt = Date()
        save()
    }

    private func recordDecision(kind: CalendarEventKind, accepted: Bool) {
        let rule = CalendarAutoRule.rule(for: kind, in: context)
        guard rule.record(accepted: accepted) else { return }
        if rule.autoApprove {
            learningNotice = "\(kind.label) will be added automatically from now on. You can change that in Settings."
        } else if rule.suppressed {
            learningNotice = "\(kind.label) won't be suggested any more. You can turn them back on in Settings."
        }
    }

    // MARK: - Store helpers

    /// Every occurrence key with a verdict, in one fetch. Fetching only the keys
    /// would be better, but SwiftData has no projection — so the rows are pruned
    /// aggressively instead (see `pruneOldSuggestions`).
    private func allDecidedKeys() -> Set<String> {
        let descriptor = FetchDescriptor<CalendarSuggestion>()
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return Set(rows.map(\.occurrenceKey))
    }

    private func insertNoActionRecord(for event: CalendarEventSnapshot, kind: CalendarEventKind) {
        context.insert(
            CalendarSuggestion(
                occurrenceKey: event.occurrenceKey,
                eventTitle: event.title,
                eventStart: event.start,
                eventIsAllDay: event.isAllDay,
                calendarTitle: event.calendarTitle,
                suggestedTitle: "",
                kind: kind,
                state: .noActionNeeded
            )
        )
    }

    private func makeSuggestion(
        from proposal: CalendarProposal,
        event: CalendarEventSnapshot,
        state: CalendarSuggestionState,
        wasAutoApproved: Bool
    ) -> CalendarSuggestion {
        CalendarSuggestion(
            occurrenceKey: event.occurrenceKey,
            eventTitle: event.title,
            eventStart: event.start,
            eventIsAllDay: event.isAllDay,
            calendarTitle: event.calendarTitle,
            suggestedTitle: proposal.title,
            suggestedNotes: proposal.notes,
            // No due date from the model means "on the day of the event".
            suggestedDueDate: proposal.dueDate ?? calendar.startOfDay(for: event.start),
            suggestedCategoryName: proposal.categoryName,
            kind: proposal.kind,
            confidence: proposal.confidence,
            rationale: proposal.rationale,
            state: state,
            wasAutoApproved: wasAutoApproved
        )
    }

    /// Creates the real reminder for a suggestion. Returns nil only if the insert
    /// couldn't be saved, in which case the caller leaves `createdReminderID` nil.
    private func createReminder(from suggestion: CalendarSuggestion) -> Reminder? {
        var notes = suggestion.suggestedNotes
        let source = "From your calendar: \(suggestion.eventTitle) on \(Self.eventDateText(suggestion.eventStart, calendar: calendar))"
        notes = notes.isEmpty ? source : "\(notes)\n\n\(source)"

        let reminder = Reminder(
            title: suggestion.suggestedTitle,
            notes: notes,
            dueDate: suggestion.suggestedDueDate,
            priority: .normal,
            category: resolveCategory(named: suggestion.suggestedCategoryName)
        )
        context.insert(reminder)
        return reminder
    }

    /// Matches the model's category name against the real categories, ignoring
    /// case. Falls back to "Misc", then to any non-habit category, then to no
    /// category at all (which still shows up in Today's uncategorized bucket) —
    /// a calendar item is never dropped just because the name didn't match, and it
    /// is never filed under Habits.
    private func resolveCategory(named name: String) -> Category? {
        let descriptor = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let categories = try? context.fetch(descriptor) else { return nil }
        let assignable = categories.filter { !$0.isHabits }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty,
           let match = assignable.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }
        return assignable.first(where: { $0.name == "Misc" }) ?? assignable.first
    }

    private func assignableCategoryNames() -> [String] {
        let descriptor = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let categories = try? context.fetch(descriptor) else { return [] }
        return categories.filter { !$0.isHabits }.map(\.name)
    }

    /// Titles of active, non-habit reminders — sent to the model so it doesn't
    /// propose something the user already has on the list.
    private func activeReminderTitles() -> [String] {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isCompleted })
        guard let reminders = try? context.fetch(descriptor) else { return [] }
        return reminders.filter { !$0.isHabit }.map(\.title)
    }

    /// Drops the dedupe ledger for events well in the past. Accepted suggestions
    /// are pruned too — the reminder they created is the lasting artifact, and the
    /// occurrence can't recur inside the scan window any more.
    private func pruneOldSuggestions(referenceDate: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.historyRetentionDays, to: referenceDate) else { return }
        let descriptor = FetchDescriptor<CalendarSuggestion>(predicate: #Predicate { $0.eventStart < cutoff })
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for row in stale where row.state != .pending {
            context.delete(row)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            context.rollback()
            state = .failed("Couldn't save calendar suggestions: \(error.localizedDescription)")
        }
    }

    // MARK: - Formatting

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    /// "Sat, Aug 2" — used in the reminder's provenance note and on the card.
    static func eventDateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}
