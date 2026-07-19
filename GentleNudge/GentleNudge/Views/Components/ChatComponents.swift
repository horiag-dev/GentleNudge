import SwiftUI
import SwiftData

// MARK: - Category-creation approval gate

/// Drives the in-chat Approve/Cancel gate for `create_category`. `ChatView` owns
/// one of these, wires `coordinator.categoryApprovalHook` to `request(name:)`, and
/// renders `pending` as a card. The tool executor suspends inside `request` until
/// the user taps, which calls `resolve(_:)` — replacing the coordinator's
/// default-deny stub with a real user decision (§2.5).
@MainActor
@Observable
final class CategoryApprovalPresenter {
    struct Pending: Identifiable {
        let id = UUID()
        let name: String
    }

    private(set) var pending: Pending?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Suspends until the user resolves the gate. Safe to `await` from the
    /// coordinator's `@Sendable` hook — hops to the main actor here.
    func request(name: String) async -> Bool {
        // Defensively resolve any orphaned prior request (shouldn't happen: turns
        // are single-in-flight and tool_uses execute serially).
        continuation?.resume(returning: false)
        continuation = nil
        return await withCheckedContinuation { cont in
            self.pending = Pending(name: name)
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

/// Compact status line shown while a turn is in flight. Non-streaming, so the
/// wording is generic (a streamed variant lands in Phase 2).
struct ChatToolStatusRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
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

// MARK: - Category approval card

struct CategoryApprovalCard: View {
    let name: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Create a new category?", systemImage: "folder.badge.plus")
                .font(.subheadline.weight(.semibold))
            Text("The assistant wants to create the category “\(name)”. Approve to add it, or cancel to pick an existing one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Approve") { onApprove() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
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
    let onPick: (String) -> Void

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
