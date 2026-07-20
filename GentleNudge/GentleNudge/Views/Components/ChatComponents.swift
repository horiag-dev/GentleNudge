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
                .background(Color.accentColor)
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
struct ChatStreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(ChatAssistantBubble.markdown(text))
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

// MARK: - Confirmation card (shared Approve/Cancel gate)

/// Renders the pending confirmation for a gated tool. Used for both
/// `create_category` (additive, accent-tinted) and `delete_reminder` (destructive,
/// red-tinted), driven by `ConfirmationPresenter.pending`.
struct ConfirmationCard: View {
    let pending: ConfirmationPresenter.Pending
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var tint: Color { pending.isDestructive ? .red : .accentColor }
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
                        .foregroundStyle(.blue)
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
    let examples: [String]
    /// When there's meaningful cleanup potential, the number of clearable items;
    /// nil hides the proactive "Clean up" suggestion.
    var cleanupCount: Int?
    let onPick: (String) -> Void

    /// The phrase pre-filled (not sent) when the cleanup suggestion is tapped.
    private let cleanupPrompt = "Clean up my list"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 4) {
                Text("Assistant")
                    .font(.title2.weight(.semibold))
                Text("Describe what you need to remember and I'll add it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                if let cleanupCount, cleanupCount > 0 {
                    Button {
                        onPick(cleanupPrompt)
                    } label: {
                        HStack(spacing: 8) {
                            Text("🧹")
                            Text("Clean up \(cleanupCount) \(cleanupCount == 1 ? "item" : "items")")
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(examples, id: \.self) { example in
                    Button {
                        onPick(example)
                    } label: {
                        Text(example)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(AppColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
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
