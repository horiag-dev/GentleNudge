import SwiftUI
import SwiftData

/// The conversational assistant surface, shared by both platforms. Owns no chat
/// state of its own — it renders the app-level `ChatCoordinator` (injected via the
/// environment so it survives macOS detail swaps / iOS tab changes) and forwards
/// input through `run(userText:)`. Chrome differs per platform via the caller's
/// `onOpenSettings` deep link.
struct ChatView: View {
    @Environment(ChatCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    /// Bumped by the iOS root (`ContentView`) whenever the Assistant tab becomes
    /// active, so the input auto-focuses and the keyboard comes up ready to
    /// type. Default (0) never fires — macOS and previews leave it untouched.
    var focusTrigger: Int = 0

    /// Settings deep link: iOS switches to the Settings tab; macOS opens the
    /// settings sheet. Nil in previews.
    var onOpenSettings: (() -> Void)?

    @State private var draft = ""
    @State private var hasAPIKey = Constants.isAPIKeyConfigured
    @State private var confirmationPresenter = ConfirmationPresenter()
    /// Presents the category editor from the no-categories gate, so the gate is
    /// actionable in place (the `@Query` clears it as soon as a category exists).
    @State private var showingAddCategory = false
    @FocusState private var inputFocused: Bool

    // Voice is no longer launched from here: the hands-free Voice mode has its
    // own top-level entry in the iOS bottom bar (see `ContentView`), which owns
    // the shared `SpeechSynthesizer`. Typed chat itself never speaks.

    private let bottomID = "chat-bottom-anchor"

    /// Time-gate for the streaming follow-scroll: scrolling to bottom on EVERY
    /// SSE delta forces a layout pass per token, so it's coalesced to ~10/sec.
    /// A reference box (not plain `@State` mutation) so bumping the timestamp
    /// doesn't itself invalidate the view.
    private final class StreamScrollGate {
        var lastScroll = Date.distantPast
    }
    @State private var streamScrollGate = StreamScrollGate()

    /// Categories a reminder can actually be filed under (excludes the habits
    /// category). Send is gated on at least one existing (§2.7).
    private var availableCategories: [Category] {
        categories.filter { !$0.isHabits }
    }

    private var hasCategories: Bool { !availableCategories.isEmpty }

    private var canSend: Bool {
        hasAPIKey
            && hasCategories
            && !coordinator.isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // The composer rides the bottom SAFE AREA edge instead of sitting as the
        // stack's last element. Safe-area-inset content is repositioned from the
        // resolved safe area on every layout pass, so when the keyboard raises
        // the bottom safe area the bar reliably lands ABOVE it — including when
        // focus is set programmatically on tab arrival, which used to leave the
        // stack-pinned field hidden behind the auto-raised keyboard on iOS.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputArea
        }
        .background(AppColors.background)
        .onAppear {
            refreshKeyState()
            wireConfirmationHooks()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshKeyState() }
        }
        .onChange(of: focusTrigger) { _, _ in
            focusInputIfReady()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button {
                startNewChat()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(coordinator.transcript.isEmpty && !coordinator.isRunning && coordinator.lastError == nil)
            .help("Start a new conversation")
            // `.help` is a no-op for VoiceOver on iOS — name the button explicitly.
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    /// True when there's no conversation to show (nothing committed, nothing
    /// in flight). Gates which resting surface renders — and keeps the no-key
    /// state from REPLACING a live transcript when the key goes missing
    /// mid-conversation (that case shows a banner over the composer instead).
    private var transcriptIsEmpty: Bool {
        coordinator.transcript.isEmpty && !coordinator.isRunning
    }

    @ViewBuilder
    private var content: some View {
        if !hasAPIKey && transcriptIsEmpty {
            ChatNoKeyState(onOpenSettings: openSettings)
        } else if transcriptIsEmpty {
            // Resting state: the assistant hero, kept near the top.
            emptyStateScroll
        } else {
            transcriptScroll
        }
    }

    private var emptyStateScroll: some View {
        ScrollView {
            // Tapping a suggestion chip only drafts the text (never auto-sends)
            // and focuses the composer, so the user stays in control.
            ChatEmptyState { suggestion in
                draft = suggestion
                inputFocused = true
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(coordinator.transcript) { item in
                        transcriptRow(item)
                    }

                    if coordinator.isRunning {
                        // Live assistant text as it streams…
                        if let streaming = coordinator.streamingText, !streaming.isEmpty {
                            ChatStreamingBubble(text: streaming)
                        }
                        // …and a per-action progress line ("Thinking…", "Adding …").
                        if let activity = coordinator.activity {
                            ChatActivityRow(activity: activity)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Short conversations sit just above the input bar (iMessage-style)
            // instead of leaving a big gap up top; also opens scrolled to newest.
            .defaultScrollAnchor(.bottom)
            // Let the user push the keyboard away by dragging the transcript, so
            // the (keyboard-covered) tab bar is always reachable again on iOS.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coordinator.transcript.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: coordinator.isRunning) { _, _ in scrollToBottom(proxy) }
            // Follow the streaming text without animating — and without
            // scrolling — on every token: coalesced to ~10/sec. The final
            // position is guaranteed by the commit-to-transcript scroll
            // (`transcript.count`) and the `isRunning` flip below/above.
            .onChange(of: coordinator.streamingText) { _, _ in
                let now = Date()
                guard now.timeIntervalSince(streamScrollGate.lastScroll) >= 0.1 else { return }
                streamScrollGate.lastScroll = now
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: coordinator.activity) { _, _ in scrollToBottom(proxy) }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            ChatUserBubble(text: text)
        case .assistant(_, let text):
            ChatAssistantBubble(text: text)
        case .notice(_, let text):
            ChatNoticeBubble(text: text)
        case .reminderCard(_, let reminderID, let title, let summary, let snapshot):
            ReminderCardView(
                reminderID: reminderID,
                title: title,
                summary: summary,
                snapshot: snapshot
            )
        case .findResult(_, let query, let rows, let total):
            FindResultCard(query: query, rows: rows, totalMatches: total)
        case .updateCard(_, _, let title, let changes):
            UpdateDiffCard(title: title, changes: changes)
        case .completionCard(_, _, let title, let isCompleted, let detail, let isUndo):
            CompletionCard(title: title, isCompleted: isCompleted, detail: detail, isUndo: isUndo)
        case .deletedCard(_, let title):
            DeletedCard(title: title)
        case .cleanupCard(_, let count, let isCompletion):
            CleanupCard(count: count, isCompletion: isCompletion)
        case .memoryCard(_, let memoryID, let content, let kind, let action):
            MemoryCard(memoryID: memoryID, content: content, kind: kind, action: action)
        }
    }

    // MARK: Input area (banner + gate + note + bar)

    private var inputArea: some View {
        VStack(spacing: 8) {
            // Key went missing MID-conversation: the transcript stays visible
            // (content no longer swaps to the no-key hero) and this notice sits
            // over the (disabled) composer with the Settings route.
            if !hasAPIKey && !transcriptIsEmpty {
                ChatNoKeyBanner(onOpenSettings: openSettings)
            }

            if let error = coordinator.lastError {
                ChatErrorBanner(
                    error: error,
                    onRetry: { coordinator.retry() },
                    onOpenSettings: openSettings,
                    onDismiss: { coordinator.clearError() }
                )
            }

            if let pending = confirmationPresenter.pending {
                ConfirmationCard(
                    pending: pending,
                    onConfirm: { confirmationPresenter.resolve(true) },
                    onCancel: { confirmationPresenter.resolve(false) }
                )
            }

            if hasAPIKey && !hasCategories {
                // Actionable gate: opens the same category editor Settings uses;
                // the `@Query`-driven `hasCategories` clears it on save.
                Button {
                    showingAddCategory = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("Add a category before the assistant can create reminders.")
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text("Add")
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a category")
                .accessibilityHint("The assistant needs at least one category before it can create reminders")
            }

            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.background)
        .sheet(isPresented: $showingAddCategory) {
            EditCategoryView(category: nil)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 620)
                #endif
        }
    }

    /// A tidy, always-single-row bar: the multiline field takes the flexible width
    /// and grows 1→5 lines *between* fixed elements, while the send button keeps a
    /// fixed size and can never be overlapped or clipped off the right edge. The
    /// software keyboard is dismissed by dragging the transcript (interactive
    /// scroll-dismiss) — no floating "Done" pill.
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Constants.Spacing.xs) {
            TextField("Message the assistant…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .disabled(!hasAPIKey || !hasCategories)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Take all the flexible width so the field compresses to fit rather
                // than pushing the fixed send button past the right edge.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                // Explicit key handling: ↩ and ⌘↩ send, ⇧↩ inserts a newline.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            // Fixed footprint pinned to the bottom of the growing field — never
            // clipped, never overlapped.
            .frame(width: 34, height: 34)
            .disabled(!canSend)
            .help("Send")
            .accessibilityLabel("Send")
        }
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAPIKey, hasCategories, !coordinator.isRunning, !text.isEmpty else { return }
        coordinator.run(userText: text)
        draft = ""
        // On macOS keep the field focused for rapid entry (no software keyboard to
        // trap). On iOS, don't force-refocus: the keyboard covers the tab bar, and
        // re-asserting focus is what trapped the user — leave dismissal to them
        // (interactive scroll-dismiss + the keyboard's Done button).
        #if os(macOS)
        inputFocused = true
        #endif
    }

    private func startNewChat() {
        // Unblock any pending confirmation gate so a stale continuation can't leak.
        confirmationPresenter.resolve(false)
        coordinator.newChat()
        draft = ""
        inputFocused = true
    }

    private func openSettings() {
        onOpenSettings?()
    }

    /// Raise the keyboard when arriving on the Assistant tab — but only when the
    /// user can actually type/send (a key AND at least one category; not the
    /// no-key or empty-category states). The focus set is deferred until well
    /// after the `TabView` has finished swapping this tab's content in: focusing
    /// while the swap is still settling raised the keyboard before keyboard
    /// avoidance was tracking the freshly-installed field, which left the
    /// composer hidden behind the keyboard.
    ///
    /// Robustness for the intermittent "keyboard didn't pop" miss:
    /// - Reset to `false` first. If `inputFocused` was left `true` from a prior
    ///   visit, assigning `true` again is a no-op and SwiftUI never re-makes the
    ///   field first responder — a `false → true` transition forces it.
    /// - Assign `true` twice. The second, later assignment re-asserts focus in
    ///   case the first landed a hair before the field was in the responder
    ///   chain; it's a no-op when the keyboard is already up, so it can't
    ///   double-fire. The user can still dismiss afterward (scroll-dismiss).
    private func focusInputIfReady() {
        guard hasAPIKey, hasCategories else { return }
        Task { @MainActor in
            inputFocused = false
            try? await Task.sleep(for: .milliseconds(300))
            inputFocused = true
            try? await Task.sleep(for: .milliseconds(350))
            inputFocused = true
        }
    }

    private func refreshKeyState() {
        hasAPIKey = Constants.isAPIKeyConfigured
    }

    /// Replace the coordinator's default-deny stubs with the in-chat gates. Both
    /// the category-creation and reminder-deletion gates share one presenter (only
    /// one is ever pending at a time — turns are single-in-flight).
    private func wireConfirmationHooks() {
        let presenter = confirmationPresenter
        coordinator.categoryApprovalHook = { name in
            await presenter.request(
                title: "Create a new category?",
                message: "The assistant wants to create the category “\(name)”. Approve to add it, or cancel to pick an existing one.",
                confirmLabel: "Approve",
                isDestructive: false
            )
        }
        coordinator.deletionApprovalHook = { title in
            await presenter.request(
                title: "Delete this reminder?",
                message: "The assistant wants to permanently delete “\(title)”. This can't be undone.",
                confirmLabel: "Delete",
                isDestructive: true
            )
        }
        coordinator.bulkDeletionApprovalHook = { count, sampleTitles in
            let noun = count == 1 ? "reminder" : "reminders"
            return await presenter.request(
                title: "Clean up \(count) \(noun)?",
                message: "The assistant wants to permanently delete \(count) \(noun). This can't be undone.",
                confirmLabel: "Delete \(count)",
                isDestructive: true,
                sampleTitles: sampleTitles
            )
        }
        coordinator.bulkCompletionApprovalHook = { count, sampleTitles in
            let noun = count == 1 ? "reminder" : "reminders"
            return await presenter.request(
                title: "Complete \(count) \(noun)?",
                message: "The assistant wants to mark \(count) \(noun) done.",
                confirmLabel: "Complete \(count)",
                isDestructive: false,
                sampleTitles: sampleTitles
            )
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Reminder.self, Category.self, UserMemory.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ChatView()
        .environment(ChatCoordinator(modelContainer: container))
        .modelContainer(container)
        .frame(width: 480, height: 640)
}
