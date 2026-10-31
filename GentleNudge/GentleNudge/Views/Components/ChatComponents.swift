import SwiftUI
import SwiftData

// MARK: - Confirmation gate (generalized)

/// Drives the in-chat Approve/Cancel gate for any destructive or taxonomy-mutating
/// tool (`create_category`, `delete_reminder`, and future bulk ops). `ChatView`
/// owns one of these, wires the coordinator's approval hooks to `request(...)`, and
/// renders `pending` as a `ConfirmationCard`. The tool executor suspends inside
/// `request` until the user taps, which calls `resolve(_:)` — replacing the
/// coordinator's default-deny stub with a real user decision (§2.5, §2.6).
@MainActor
@Observable
final class ConfirmationPresenter {
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let isDestructive: Bool
        /// Sample of item titles for a batch gate (e.g. bulk delete). Empty for
        /// single-item gates. Rendered as a short bulleted preview + "+N more".
        var sampleTitles: [String] = []
    }

    private(set) var pending: Pending?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Suspends until the user resolves the gate. Safe to `await` from a
    /// coordinator `@Sendable` hook — hops to the main actor here. Only one gate is
    /// ever pending at a time (turns are single-in-flight; tool_uses run serially).
    func request(
        title: String,
        message: String,
        confirmLabel: String,
        isDestructive: Bool,
        sampleTitles: [String] = []
    ) async -> Bool {
        // Defensively resolve any orphaned prior request.
        continuation?.resume(returning: false)
        continuation = nil
        return await withCheckedContinuation { cont in
            self.pending = Pending(
                title: title, message: message, confirmLabel: confirmLabel,
                isDestructive: isDestructive, sampleTitles: sampleTitles
            )
            self.continuation = cont
        }
    }

    /// Resolves the current gate (no-op if nothing is pending). Called by the
    /// Approve/Cancel buttons and by "New chat" to unblock a stale gate.
    func resolve(_ approved: Bool) {
        pending = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

// MARK: - Message bubbles

struct ChatUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

struct ChatAssistantBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(Self.markdown(text))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
            Spacer(minLength: 40)
        }
    }

    /// Render minimal markdown inline (bold/italic/links). Falls back to the raw
    /// string if parsing fails. Uses `AttributedString(markdown:)`, not
    /// `Text(markdown:)`, so multi-paragraph replies keep their soft breaks.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct ChatNoticeBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }
}

/// The assistant's text as it streams in, token by token. Mirrors
/// `ChatAssistantBubble`'s styling so the handoff to the committed transcript
/// item is seamless when the message completes.
///
/// While streaming the text renders PLAIN (no markdown parse): re-running
/// `AttributedString(markdown:)` over the whole accumulated text on every
/// delta is O(len²) across a reply. The committed `ChatAssistantBubble`
/// parses markdown once on completion, so the final render is unchanged.
struct ChatStreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
            Spacer(minLength: 40)
        }
    }
}

/// Live per-turn progress line: a spinner plus what the assistant is actually
/// doing right now ("Thinking…", "Adding “Pay rent”…"). Replaces the old static
/// "Working…" spinner.
struct ChatActivityRow: View {
    let activity: ChatActivity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var label: String {
        switch activity {
        case .thinking: return "Thinking…"
        case .working(let phrase): return "\(phrase)…"
        }
    }
}

// MARK: - Reminder card (live-bound, snapshot-gated actions)

/// A read-only confirmation card for one chat-created reminder. Live-binds to the
/// store through a **dynamically-initialized `@Query`** keyed by the reminder's
/// UUID: 0 matches → muted "Removed"; 1 → normal; >1 → show the first (UUID is not
/// unique-constrained) without crashing. Its action is **Undo** while the reminder
/// still matches its creation snapshot, and a confirmed **Delete** once changed.
struct ReminderCardView: View {
    @Environment(ChatCoordinator.self) private var coordinator

    private let reminderID: UUID
    private let fallbackTitle: String
    private let summary: String
    private let snapshot: ReminderSnapshot

    @Query private var matches: [Reminder]

    @State private var showDeleteConfirm = false
    @State private var isEditing = false

    init(reminderID: UUID, title: String, summary: String, snapshot: ReminderSnapshot) {
        self.reminderID = reminderID
        self.fallbackTitle = title
        self.summary = summary
        self.snapshot = snapshot
        let id = reminderID
        _matches = Query(
            filter: #Predicate<Reminder> { $0.id == id },
            sort: \.createdAt,
            order: .forward
        )
    }

    var body: some View {
        HStack {
            Group {
                if let reminder = matches.first {
                    loadedCard(reminder)
                } else {
                    removedCard
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 40)
        }
    }

    // MARK: 1+ match

    @ViewBuilder
    private func loadedCard(_ reminder: Reminder) -> some View {
        let pristine = snapshot.matchesCreation(reminder)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.title)
                        .font(.headline)
                        .strikethrough(reminder.isCompleted)

                    if !reminder.notes.isEmpty {
                        Text(reminder.notes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let category = reminder.category {
                            CategoryChip(category: category, size: .small)
                        }
                        if reminder.priority == .urgent {
                            Label("Urgent", systemImage: "exclamationmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        }
                    }

                    if let due = reminder.formattedDueDate {
                        Label(due, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }

                    if let recurrence = reminder.detailedRecurrence {
                        Label(recurrence, systemImage: "repeat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                if pristine {
                    Button {
                        remove()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Spacer(minLength: 0)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog(
            "Delete this reminder?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reminder has changed since it was created. Deleting it can't be undone.")
        }
        .sheet(isPresented: $isEditing) {
            editorSheet(reminder)
        }
    }

    @ViewBuilder
    private func editorSheet(_ reminder: Reminder) -> some View {
        #if os(iOS)
        NavigationStack {
            ReminderDetailView(reminder: reminder)
        }
        #else
        NavigationStack {
            ReminderDetailView(reminder: reminder)
                .frame(minWidth: 420, minHeight: 560)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isEditing = false }
                    }
                }
        }
        #endif
    }

    // MARK: 0 matches

    private var removedCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(fallbackTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text("Removed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppColors.secondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func remove() {
        let id = reminderID
        Task { await coordinator.deleteReminder(id: id) }
    }
}

// MARK: - Quick add (Today)

/// A one-line composer on Today that hands whatever is typed or pasted — one
/// todo or a whole list — straight to the assistant, without leaving Today.
/// While the turn runs it shows the live activity ("Adding 25 reminders…");
/// afterwards a one-line result with "Open chat" to see the cards. Anything
/// needing a decision (a new category, a delete) brings the Assistant forward
/// on its own via `ContentView`.
struct QuickAddBar: View {
    @Environment(ChatCoordinator.self) private var coordinator

    @State private var text = ""
    /// Transcript length when this bar started a turn; nil when it didn't.
    @State private var startIndex: Int?
    @State private var outcome: Outcome?
    @FocusState private var focused: Bool

    private enum Outcome: Equatable {
        case added(count: Int, reply: String?)
        case replied(String)
        case failed
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isMine: Bool { startIndex != nil && coordinator.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            HStack(alignment: .bottom, spacing: Constants.Spacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 3)
                TextField("Add a todo, or paste a whole list", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .disabled(isMine)
                if !trimmed.isEmpty || isMine {
                    Button(action: send) {
                        if isMine {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(isMine)
                    .accessibilityLabel("Send to assistant")
                }
            }
            .padding(.horizontal, Constants.Spacing.sm)
            .padding(.vertical, Constants.Spacing.xs)
            .background(AppColors.secondaryBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if isMine {
                Text(activityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Constants.Spacing.sm)
                    .transition(.opacity)
            } else if let outcome {
                outcomeRow(outcome)
                    .padding(.horizontal, Constants.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isMine)
        .animation(.easeInOut(duration: 0.2), value: outcome)
        .onChange(of: coordinator.isRunning) { _, running in
            guard !running, let start = startIndex else { return }
            startIndex = nil
            outcome = Self.summarize(coordinator.transcript, from: start, failed: coordinator.lastError != nil)
        }
    }

    private var activityText: String {
        switch coordinator.activity {
        case .working(let phrase): return "\(phrase)…"
        default: return "Thinking…"
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: Outcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Spacing.xs) {
            switch outcome {
            case .added(let count, let reply):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Added \(count) reminder\(count == 1 ? "" : "s")" + (reply.map { " · \($0)" } ?? ""))
                    .lineLimit(2)
            case .replied(let reply):
                Image(systemName: "bubble.left.fill").foregroundStyle(.secondary)
                Text(reply).lineLimit(2)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't reach the assistant.")
            }
            Spacer(minLength: 0)
            Button("Open chat") { coordinator.requestAssistant() }
                .buttonStyle(.borderless)
            Button {
                self.outcome = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .font(.caption)
    }

    private func send() {
        guard !trimmed.isEmpty, !coordinator.isRunning else { return }
        let message = trimmed
        outcome = nil
        // Run first: `run` appends the user message, so the turn's output
        // starts after it.
        coordinator.run(userText: message)
        startIndex = coordinator.transcript.count
        text = ""
        focused = false
    }

    private static func summarize(_ transcript: [TranscriptItem], from start: Int, failed: Bool) -> Outcome? {
        guard start <= transcript.count else { return nil }
        var added = 0
        var reply: String?
        for item in transcript[start...] {
            switch item {
            case .reminderCard: added += 1
            case .batchCreatedCard(_, let items): added += items.count
            case .assistant(_, let text), .notice(_, let text): reply = text
            default: break
            }
        }
        if added > 0 { return .added(count: added, reply: reply) }
        if failed { return .failed }
        return reply.map { .replied($0) }
    }
}

// MARK: - Batch created card (create_reminders)

/// One card for a whole `create_reminders` batch: a count header, a compact
/// list of titles (first few, then "Show all"), and **Undo all**. Live-binds to
/// the store through a dynamic `@Query` over the batch's ids, so rows removed
/// elsewhere drop out. Undo only removes reminders still matching their creation
/// snapshot; anything edited or completed since is kept.
struct BatchCreatedCard: View {
    @Environment(ChatCoordinator.self) private var coordinator

    private let items: [BatchCreatedItem]
    @Query private var matches: [Reminder]
    @State private var showAll = false

    private static let collapsedCount = 6

    init(items: [BatchCreatedItem]) {
        self.items = items
        let ids = items.map(\.reminderID)
        _matches = Query(filter: #Predicate<Reminder> { ids.contains($0.id) })
    }

    private var live: [UUID: Reminder] {
        Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let live = live
        let present = items.filter { live[$0.reminderID] != nil }
        let undoable = present.filter { item in
            live[item.reminderID].map { item.snapshot.matchesCreation($0) } ?? false
        }
        let shown = showAll ? present : Array(present.prefix(Self.collapsedCount))

        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: present.isEmpty ? "trash" : "checkmark.circle.fill")
                        .foregroundStyle(present.isEmpty ? Color.secondary : Color.green)
                        .font(.title3)
                    Text(present.isEmpty
                         ? "Removed \(items.count) reminders"
                         : "Added \(present.count) reminder\(present.count == 1 ? "" : "s")")
                        .font(.headline)
                        .foregroundStyle(present.isEmpty ? .secondary : .primary)
                }

                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown) { item in
                            let reminder = live[item.reminderID]
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reminder?.title ?? item.title)
                                    .font(.subheadline)
                                    .strikethrough(reminder?.isCompleted ?? false)
                                    .lineLimit(2)
                                if !item.summary.isEmpty {
                                    Text(item.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.leading, 4)
                }

                if !present.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        if present.count > Self.collapsedCount {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                            } label: {
                                Label(showAll ? "Show less" : "Show all \(present.count)",
                                      systemImage: showAll ? "chevron.up" : "chevron.down")
                            }
                        }
                        if !undoable.isEmpty {
                            Button {
                                undo(undoable)
                            } label: {
                                Label(undoable.count == present.count ? "Undo all" : "Undo \(undoable.count)",
                                      systemImage: "arrow.uturn.backward")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground.opacity(present.isEmpty ? 0.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    private func undo(_ targets: [BatchCreatedItem]) {
        let ids = targets.map(\.reminderID)
        Task { await coordinator.deleteReminders(ids: ids) }
    }
}

// MARK: - Confirmation card (shared Approve/Cancel gate)

/// Renders the pending confirmation for a gated tool. Used for both
/// `create_category` (additive, accent-tinted) and `delete_reminder` (destructive,
/// red-tinted), driven by `ConfirmationPresenter.pending`.
struct ConfirmationCard: View {
    let pending: ConfirmationPresenter.Pending
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var tint: Color { pending.isDestructive ? .red : AppColors.accent }
    private var icon: String { pending.isDestructive ? "trash" : "folder.badge.plus" }

    /// At most this many sample titles are listed; the rest collapse to "+N more".
    private let sampleLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pending.title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Text(pending.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !pending.sampleTitles.isEmpty {
                sampleList
            }
            HStack(spacing: 12) {
                Button(pending.confirmLabel, role: pending.isDestructive ? .destructive : nil) { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    /// A short preview of the affected titles for a batch gate, capped at
    /// `sampleLimit` with a "+N more" overflow line.
    private var sampleList: some View {
        let shown = pending.sampleTitles.prefix(sampleLimit)
        let overflow = pending.sampleTitles.count - shown.count
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, title in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - find_reminders result card

/// A compact result list for `find_reminders`: header count, up to 5 tappable
/// rows, and a "+N more" overflow. Tapping a row opens that reminder's detail
/// sheet (the "jump to it in the app" affordance).
struct FindResultCard: View {
    let query: String?
    let rows: [FindRow]
    let totalMatches: Int

    @State private var selected: FindRow?

    private var visibleRows: [FindRow] { Array(rows.prefix(5)) }
    private var overflow: Int { max(0, totalMatches - visibleRows.count) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Label(headerText, systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if rows.isEmpty {
                    Text("No matching reminders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            Button { selected = row } label: { FindResultRow(row: row) }
                                .buttonStyle(.plain)
                            if row.id != visibleRows.last?.id { Divider() }
                        }
                    }
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
        .sheet(item: $selected) { row in
            ReminderDetailLoader(reminderID: row.id, fallbackTitle: row.title)
        }
    }

    private var headerText: String {
        let noun = totalMatches == 1 ? "reminder" : "reminders"
        if let query, !query.isEmpty {
            return "\(totalMatches) \(noun) matching “\(query)”"
        }
        return "\(totalMatches) \(noun)"
    }
}

struct FindResultRow: View {
    let row: FindRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(row.isCompleted ? .green : (row.isOverdue ? .red : .secondary))
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline)
                    .strikethrough(row.isCompleted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let due = row.dueDisplay {
                        Label(due, systemImage: "calendar")
                            .foregroundStyle(row.isOverdue ? .red : .secondary)
                    }
                    if let category = row.category { Text(category) }
                    if let recurrence = row.recurrence {
                        Label(recurrence, systemImage: "repeat")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Loads one reminder by UUID for the find-result "jump to" sheet. Live-binds via
/// a dynamic `@Query`; shows a muted fallback if the reminder has since vanished.
struct ReminderDetailLoader: View {
    @Environment(\.dismiss) private var dismiss
    let fallbackTitle: String
    @Query private var matches: [Reminder]

    init(reminderID: UUID, fallbackTitle: String) {
        self.fallbackTitle = fallbackTitle
        let id = reminderID
        _matches = Query(filter: #Predicate<Reminder> { $0.id == id })
    }

    var body: some View {
        if let reminder = matches.first {
            detail(reminder)
        } else {
            missing
        }
    }

    @ViewBuilder
    private func detail(_ reminder: Reminder) -> some View {
        #if os(iOS)
        NavigationStack {
            ReminderDetailView(reminder: reminder)
        }
        #else
        NavigationStack {
            ReminderDetailView(reminder: reminder)
                .frame(minWidth: 420, minHeight: 560)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("“\(fallbackTitle)” is no longer available.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
        }
        .padding(40)
    }
}

// MARK: - update_reminder diff card

struct UpdateDiffCard: View {
    let title: String
    let changes: [ReminderFieldChange]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(AppColors.accent)
                    Text("Updated \(title)")
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(changes) { change in
                    HStack(spacing: 4) {
                        Text(change.label)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(change.value)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - complete / uncomplete card

struct CompletionCard: View {
    let title: String
    let isCompleted: Bool
    let detail: String?
    let isUndo: Bool

    private var icon: String { isUndo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill" }
    private var tint: Color { isUndo ? .orange : .green }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(isCompleted && !isUndo)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - delete result card (muted)

struct DeletedCard: View {
    let title: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Text("Deleted")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - batch cleanup result card (muted)

/// The muted result of a confirmed batch: "Cleaned up N items" for a bulk delete,
/// "Completed N items" for a bulk complete. Mirrors `DeletedCard`'s quiet styling.
struct CleanupCard: View {
    let count: Int
    let isCompletion: Bool

    private var icon: String { isCompletion ? "checkmark.circle.fill" : "trash" }
    private var noun: String { count == 1 ? "item" : "items" }
    private var text: String {
        isCompletion ? "Completed \(count) \(noun)" : "Cleaned up \(count) \(noun)"
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(isCompletion ? Color.green.opacity(0.7) : Color.secondary)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(12)
            .background(AppColors.secondaryBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Memory card (remember / update_memory)

/// Confirmation card for the memory tools: "Remembered" / "Updated memory" with
/// the saved fact and a lightweight Forget action, or a muted "Forgot that" for
/// a deletion. Live-binds to the store through a dynamically-initialized
/// `@Query` keyed by the memory's UUID (like `ReminderCardView`), so Forget —
/// or a deletion from Settings — collapses the card to its muted state.
struct MemoryCard: View {
    @Environment(ChatCoordinator.self) private var coordinator

    private let memoryID: UUID
    private let fallbackContent: String
    private let kind: String
    private let action: MemoryCardAction

    @Query private var matches: [UserMemory]

    init(memoryID: UUID, content: String, kind: String, action: MemoryCardAction) {
        self.memoryID = memoryID
        self.fallbackContent = content
        self.kind = kind
        self.action = action
        let id = memoryID
        _matches = Query(filter: #Predicate<UserMemory> { $0.id == id })
    }

    var body: some View {
        HStack {
            Group {
                if action != .forgotten, let memory = matches.first {
                    loadedCard(memory)
                } else {
                    forgottenCard
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 40)
        }
    }

    private var headerText: String {
        action == .updated ? "Updated memory" : "Remembered"
    }

    @ViewBuilder
    private func loadedCard(_ memory: UserMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(AppColors.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headerText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(memory.content)
                        .font(.subheadline)
                    Text(memory.kind.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppColors.background)
                        .clipShape(Capsule())
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    forget()
                } label: {
                    Label(action == .updated ? "Forget" : "Undo", systemImage: "arrow.uturn.backward")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Shown for a `update_memory` deletion, or after Undo/Forget removed the
    /// memory. Mirrors `DeletedCard`'s quiet styling.
    private var forgottenCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(fallbackContent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text("Forgot that")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppColors.secondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func forget() {
        let id = memoryID
        Task { await coordinator.deleteMemory(id: id) }
    }
}

// MARK: - Error banner

struct ChatErrorBanner: View {
    let error: ChatError
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    if error.needsSettings {
                        Button("Open Settings", action: onOpenSettings)
                    } else if error.isRetryable {
                        Button("Retry", action: onRetry)
                    }
                    Button("Dismiss", action: onDismiss)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Empty / no-key states

struct ChatEmptyState: View {
    /// Called with the tapped example prompt. The host puts it in the input
    /// draft and focuses the composer — never auto-sends. Nil hides the chips.
    var onSuggestion: ((String) -> Void)? = nil

    /// Example prompts chosen to teach the tool range: querying, creating into
    /// a category, and the long-term memory.
    private static let suggestions: [String] = [
        "What's due today?",
        "Add 'buy milk' to Errands",
        "Remember my wife's name is Sarah",
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.accent)
            VStack(spacing: 4) {
                Text("Assistant")
                    .font(.title2.weight(.semibold))
                Text("Describe what you need to remember and I'll add it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let onSuggestion {
                VStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            onSuggestion(suggestion)
                        } label: {
                            Text("“\(suggestion)”")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(AppColors.secondaryBackground)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Puts this example in the message field")
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }
}

/// Compact notice shown ABOVE the composer when the API key goes missing
/// MID-conversation: the transcript stays visible (swapping in the full
/// `ChatNoKeyState` made the whole conversation appear to vanish), the
/// composer is disabled, and this carries the Settings route.
struct ChatNoKeyBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Claude API key is missing. Add it in Settings to continue the conversation.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Button("Open Settings", action: onOpenSettings)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ChatNoKeyState: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect your Claude key")
                .font(.title3.weight(.semibold))
            Text("The assistant uses your own Claude API key, stored securely in your Keychain. Nothing is sent anywhere else.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                onOpenSettings()
            } label: {
                Text("Set up in Settings")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)

            Link(destination: URL(string: "https://console.anthropic.com/")!) {
                Label("Get API Key", systemImage: "arrow.up.right.square")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
