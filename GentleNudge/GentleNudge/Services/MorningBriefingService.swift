import Foundation
import Observation

// MARK: - Output

/// The two products of one morning-briefing generation. Both are plain text
/// (no markdown / emoji), safe to drop straight into a notification body or a
/// SwiftUI `Text`.
struct MorningBriefing: Sendable, Equatable {
    /// A single short sentence ("important work first") for the local
    /// notification body — path (a).
    let notificationBody: String
    /// A slightly fuller 2–4 sentence briefing for the in-app card — path (b).
    let inAppBriefing: String
}

// MARK: - Service

/// Builds a small prompt from the user's overdue / due-today / near-term
/// reminders and makes ONE small, non-tool LLM call to produce a prioritized
/// morning briefing. The network runs off the main actor (inside
/// `AnthropicClient`). Every failure mode — no API key, malformed reply,
/// network error, or the hard timeout — resolves to `nil` so callers fall back
/// to the existing non-AI behavior.
///
/// Design notes:
/// - Model: `Constants.chatModel` (honors the user's selection).
/// - Effort: a fixed `.low` — the briefing is a simple, latency-sensitive
///   summarize, not a reasoning task, and the iOS background window is short.
/// - `max_tokens`: 256. Tools: none. Thinking: disabled.
/// - Timeout: a hard ~10s race so a slow/offline call can never hang a caller.
actor MorningBriefingService {

    // MARK: Value snapshots (decoupled from the main-actor @Model)

    /// A minimal, `Sendable` snapshot of a reminder, built on the main actor by
    /// callers and handed to the service so prompt-building stays off the model.
    struct ReminderSummary: Sendable, Equatable {
        let title: String
        let categoryName: String?
        let dueDate: Date?
        let isHabit: Bool
        let isCompleted: Bool

        init(title: String, categoryName: String?, dueDate: Date?, isHabit: Bool, isCompleted: Bool) {
            self.title = title
            self.categoryName = categoryName
            self.dueDate = dueDate
            self.isHabit = isHabit
            self.isCompleted = isCompleted
        }
    }

    /// A reminder selected for the briefing, tagged with its urgency bucket.
    struct Candidate: Sendable, Equatable {
        enum Bucket: String, Sendable { case overdue, dueToday, upcoming }
        let title: String
        let categoryName: String?
        let bucket: Bucket
        /// Human-readable relative due text ("3 days ago", "today", "in 2 days").
        let dueText: String
    }

    private let client: AnthropicClient
    private let timeout: TimeInterval

    init(client: AnthropicClient = AnthropicClient(), timeout: TimeInterval = 10) {
        self.client = client
        self.timeout = timeout
    }

    // MARK: "Important work" selection (deterministic, pure)

    /// Selects the reminders worth briefing, in priority order:
    /// **overdue first** (most overdue first), then **due today**, then
    /// near-term **upcoming** (≤ `maxUpcomingDays`). Habits and completed items
    /// are excluded — a habit is never "work". Undated items are excluded (no
    /// deadline to prioritize). This is where "important work" is defined.
    nonisolated static func selectCandidates(
        from reminders: [ReminderSummary],
        referenceDate: Date,
        calendar: Calendar,
        maxUpcomingDays: Int = 2,
        limit: Int = 12
    ) -> [Candidate] {
        let today = calendar.startOfDay(for: referenceDate)
        var ranked: [(sortKey: Int, dayDelta: Int, candidate: Candidate)] = []

        for reminder in reminders {
            guard !reminder.isHabit, !reminder.isCompleted else { continue }
            guard let due = reminder.dueDate else { continue }

            let dueDay = calendar.startOfDay(for: due)
            let delta = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0

            let bucket: Candidate.Bucket
            if delta < 0 {
                bucket = .overdue
            } else if delta == 0 {
                bucket = .dueToday
            } else if delta <= maxUpcomingDays {
                bucket = .upcoming
            } else {
                continue
            }

            let sortKey = bucket == .overdue ? 0 : (bucket == .dueToday ? 1 : 2)
            ranked.append((
                sortKey: sortKey,
                dayDelta: delta,
                candidate: Candidate(
                    title: reminder.title,
                    categoryName: reminder.categoryName,
                    bucket: bucket,
                    dueText: dueText(delta: delta)
                )
            ))
        }

        // Overdue → due today → upcoming; within a bucket, most-overdue / soonest
        // first (both mean "smaller delta first").
        ranked.sort { a, b in
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            return a.dayDelta < b.dayDelta
        }
        return Array(ranked.prefix(limit).map { $0.candidate })
    }

    nonisolated static func dueText(delta: Int) -> String {
        switch delta {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "1 day ago"
        case ..<0: return "\(-delta) days ago"
        default: return "in \(delta) days"
        }
    }

    // MARK: Prompt building (deterministic, pure)

    static let systemPrompt: String = """
    You are a concise morning-briefing assistant inside a personal reminders \
    app. You are given the user's active tasks, already grouped by urgency. \
    Write a short, warm, prioritized briefing that puts the most important work \
    first. Only mention tasks that are listed — never invent, infer, or pad. No \
    emoji, no markdown.

    Respond in EXACTLY this format, each label on its own line:
    NOTIFICATION: <one short sentence, ~15 words max, naming the single most \
    important thing to tackle first>
    BRIEFING: <2 to 4 short sentences: what to do first, then what's coming up, \
    encouraging but not fluffy>
    """

    nonisolated static func buildUserPrompt(
        candidates: [Candidate],
        referenceDate: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        maxUpcomingDays: Int = 2
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        let dateString = formatter.string(from: referenceDate)

        func lines(_ bucket: Candidate.Bucket) -> String {
            candidates
                .filter { $0.bucket == bucket }
                .map { candidate in
                    let category = candidate.categoryName.map { " (\($0))" } ?? ""
                    // The due text is informative for overdue / upcoming; redundant
                    // for "due today", which the section header already states.
                    let due = bucket == .dueToday ? "" : " — \(candidate.dueText)"
                    return "- \(candidate.title)\(category)\(due)"
                }
                .joined(separator: "\n")
        }

        var sections: [String] = ["Today is \(dateString). Timezone \(timeZone.identifier)."]
        let overdue = lines(.overdue)
        let dueToday = lines(.dueToday)
        let upcoming = lines(.upcoming)
        if !overdue.isEmpty { sections.append("OVERDUE (most important, do these first):\n\(overdue)") }
        if !dueToday.isEmpty { sections.append("DUE TODAY:\n\(dueToday)") }
        if !upcoming.isEmpty { sections.append("COMING UP (next \(maxUpcomingDays) days):\n\(upcoming)") }
        sections.append("Write the briefing now.")
        return sections.joined(separator: "\n\n")
    }

    // MARK: Response parsing (lenient)

    /// Parses the labeled reply into a `MorningBriefing`. Tolerant of a missing
    /// label, extra whitespace, or a single unlabeled blob. Returns `nil` only
    /// when there's no usable text at all (caller then falls back).
    nonisolated static func parse(_ response: String) -> MorningBriefing? {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var notification: String?
        var briefing: String?

        if let nRange = text.range(of: "NOTIFICATION:", options: .caseInsensitive) {
            let after = text[nRange.upperBound...]
            if let bRange = after.range(of: "BRIEFING:", options: .caseInsensitive) {
                notification = String(after[..<bRange.lowerBound])
                briefing = String(after[bRange.upperBound...])
            } else {
                notification = String(after)
            }
        } else if let bRange = text.range(of: "BRIEFING:", options: .caseInsensitive) {
            briefing = String(text[bRange.upperBound...])
        }

        // No labels at all: treat the whole reply as the briefing.
        if notification == nil, briefing == nil { briefing = text }

        let cleanedNotification = clean(notification)
        let cleanedBriefing = clean(briefing)

        // Fill either side from the other so neither product is empty.
        let notificationBody = cleanedNotification.isEmpty ? firstSentence(cleanedBriefing) : cleanedNotification
        let inApp = cleanedBriefing.isEmpty ? cleanedNotification : cleanedBriefing

        guard !notificationBody.isEmpty, !inApp.isEmpty else { return nil }
        return MorningBriefing(notificationBody: notificationBody, inAppBriefing: inApp)
    }

    private nonisolated static func clean(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func firstSentence(_ text: String) -> String {
        guard let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else {
            return text
        }
        return String(text[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Deterministic non-AI fallback

    /// A locally-built briefing used by the in-app path when the AI call can't
    /// run (no key / error / timeout) but there ARE tasks to surface — so the
    /// card is still useful without a network call.
    nonisolated static func localFallbackBriefing(candidates: [Candidate]) -> MorningBriefing {
        let overdue = candidates.filter { $0.bucket == .overdue }
        let dueToday = candidates.filter { $0.bucket == .dueToday }
        let upcoming = candidates.filter { $0.bucket == .upcoming }
        let top = candidates.first

        let notificationBody: String
        switch top?.bucket {
        case .overdue: notificationBody = "Start with \(top!.title) — it's overdue."
        case .dueToday: notificationBody = "\(top!.title) is due today."
        case .upcoming: notificationBody = "\(top!.title) is coming up."
        case nil: notificationBody = "You're all caught up."
        }

        var parts: [String] = []
        if !overdue.isEmpty { parts.append("\(overdue.count) overdue") }
        if !dueToday.isEmpty { parts.append("\(dueToday.count) due today") }
        if !upcoming.isEmpty { parts.append("\(upcoming.count) coming up") }

        let inApp: String
        if parts.isEmpty {
            inApp = "Nothing needs your attention right now."
        } else {
            let counts = "You have \(parts.joined(separator: ", "))."
            inApp = top.map { "\(counts) Start with \($0.title)." } ?? counts
        }
        return MorningBriefing(notificationBody: notificationBody, inAppBriefing: inApp)
    }

    // MARK: Generation

    /// Makes the single non-tool LLM call for the given pre-selected candidates.
    /// Returns `nil` on no-API-key, empty candidates, malformed reply, network
    /// error, or timeout — the caller falls back.
    func generate(
        candidates: [Candidate],
        referenceDate: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) async -> MorningBriefing? {
        guard Constants.isAPIKeyConfigured, !candidates.isEmpty else { return nil }

        let userPrompt = Self.buildUserPrompt(
            candidates: candidates,
            referenceDate: referenceDate,
            calendar: calendar,
            timeZone: timeZone
        )
        let request = MessagesRequest(
            model: Constants.chatModel.rawValue,
            max_tokens: 256,
            system: [SystemBlock(text: Self.systemPrompt, cache_control: nil)],
            messages: [MessageParam(role: "user", content: [.text(userPrompt)])],
            tools: [],
            tool_choice: nil,
            output_config: OutputConfig(effort: ReasoningEffort.low.rawValue),
            thinking: ThinkingConfig(type: "disabled"),
            stream: nil
        )

        let client = self.client
        do {
            let response = try await Self.withTimeout(seconds: timeout) {
                try await client.send(request)
            }
            return Self.parse(response.textContent)
        } catch {
            return nil
        }
    }

    // MARK: Timeout

    private struct TimeoutError: Error {}

    /// Races `operation` against a sleep; whichever finishes first wins and the
    /// loser is cancelled. `AnthropicClient.send` honors cancellation (its
    /// `URLSession` request is torn down), so a timeout also cancels the network.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - In-app card view model

/// Drives the once-a-day in-app `MorningBriefingCard`. Owns the display state
/// and the "already shown today" gate (an `@AppStorage`-style UserDefaults day
/// key) so foregrounding repeatedly can't re-generate or re-cost. `@MainActor`;
/// the network hop happens inside the actor it awaits.
@MainActor
@Observable
final class MorningBriefingViewModel {

    enum DisplayState: Equatable {
        case hidden
        case loading
        case shown(MorningBriefing)
    }

    private(set) var state: DisplayState = .hidden

    /// The calendar day the current `.shown` briefing belongs to. Lets an app
    /// left running across midnight (typically the Mac) drop yesterday's
    /// briefing and generate a fresh one, instead of showing it forever.
    private var shownDay: Date?

    private let service: MorningBriefingService
    private let calendar: Calendar
    private static let lastShownDayKey = "morningBriefingLastShownDay"

    init(service: MorningBriefingService = MorningBriefingService()) {
        self.service = service
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
    }

    private var todayKey: String { Self.dayKey(for: Date(), calendar: calendar) }

    /// Call on first foreground / appear each day. Gated to run once per calendar
    /// day; safe to call repeatedly (dedupes). Shows an AI briefing when possible,
    /// a deterministic local summary if the AI call can't run, and nothing at all
    /// when there's no important work.
    func refreshIfNeeded(reminders: [MorningBriefingService.ReminderSummary]) async {
        // Already loading → nothing to do.
        if state == .loading { return }
        if case .shown = state {
            // Shown TODAY → nothing to do. But on a long-running app the day
            // can roll over while the briefing stays on screen; then reset so
            // a fresh briefing can generate (the once-per-day UserDefaults
            // gate below still applies, so this never regenerates same-day).
            if let shownDay, calendar.isDate(shownDay, inSameDayAs: Date()) { return }
            state = .hidden
            shownDay = nil
        }
        // Already handled today (shown or dismissed) → skip.
        guard UserDefaults.standard.string(forKey: Self.lastShownDayKey) != todayKey else { return }
        // Empty could mean "no data yet" (CloudKit still syncing) as easily as
        // "genuinely nothing" — wait rather than marking the day handled.
        guard !reminders.isEmpty else { return }

        let candidates = MorningBriefingService.selectCandidates(
            from: reminders,
            referenceDate: Date(),
            calendar: calendar
        )
        guard !candidates.isEmpty else {
            // Nothing important today — record it so we don't re-check all day.
            markHandledToday()
            return
        }

        state = .loading
        let briefing = await service.generate(
            candidates: candidates,
            referenceDate: Date(),
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        // Respect a dismissal that happened while we were generating.
        guard state == .loading else { return }
        state = .shown(briefing ?? MorningBriefingService.localFallbackBriefing(candidates: candidates))
        shownDay = Date()
        markHandledToday()
    }

    /// Dismiss for the rest of the day.
    func dismiss() {
        state = .hidden
        shownDay = nil
        markHandledToday()
    }

    private func markHandledToday() {
        UserDefaults.standard.set(todayKey, forKey: Self.lastShownDayKey)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
