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
    @Query private var allReminders: [Reminder]

    /// Settings deep link: iOS switches to the Settings tab; macOS opens the
    /// settings sheet. Nil in previews.
    var onOpenSettings: (() -> Void)?

    @State private var draft = ""
    @State private var hasAPIKey = Constants.isAPIKeyConfigured
    @State private var confirmationPresenter = ConfirmationPresenter()
    @FocusState private var inputFocused: Bool

    // Two-way voice: dictation (STT) into the draft + auto-send, and reading the
    // assistant's replies aloud (TTS). Both are Apple-frameworks-only and degrade
    // gracefully when unavailable/denied. See SpeechService / SpeechSynthesizer.
    @State private var speech = SpeechService()
    @State private var synthesizer = SpeechSynthesizer()
    @State private var showMicDeniedAlert = false

    private let bottomID = "chat-bottom-anchor"

    private let examplePrompts = [
        "Call the dentist next Tuesday",
        "Pay rent monthly on the 1st",
        "Read Atomic Habits, chapter 5"
    ]

    /// Categories a reminder can actually be filed under (excludes the habits
    /// category). Send is gated on at least one existing (§2.7).
    private var availableCategories: [Category] {
        categories.filter { !$0.isHabitCategory && $0.name != "Habits" }
    }

    private var hasCategories: Bool { !availableCategories.isEmpty }

    /// Proactive cleanup potential for the empty-state offer. Counts completed
    /// reminders (safe to clear) plus non-habit reminders overdue by more than 14
    /// days (stale). The offer shows when there are ≥ 5 completed OR any very-stale
    /// reminder; `count` is the total of both kinds. Nil hides the offer.
    private var cleanupCount: Int? {
        var completed = 0
        var stale = 0
        for r in allReminders {
            if r.isCompleted { completed += 1; continue }
            if r.isHabit { continue }
            if let days = r.daysUntilDue, days < -14 { stale += 1 }
        }
        let count = completed + stale
        let meaningful = completed >= 5 || stale > 0
        return (meaningful && count > 0) ? count : nil
    }

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
            inputArea
        }
        .background(AppColors.background)
        .onAppear {
            refreshKeyState()
            wireConfirmationHooks()
            wireVoice()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshKeyState() }
        }
        // Mirror the recognizer's live partial into the input field while listening.
        .onChange(of: speech.partialTranscript) { _, newValue in
            if speech.isListening { draft = newValue }
        }
        // Permission refused / unavailable → point the user at System Settings once.
        .onChange(of: speech.authorizationDenied) { _, denied in
            if denied { showMicDeniedAlert = true }
        }
        .alert("Microphone access needed", isPresented: $showMicDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To dictate messages, enable Microphone and Speech Recognition for GentleNudge in System Settings.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            // TTS mute toggle: reads/persists `voiceRepliesEnabled`. Muting also
            // stops any in-progress speech (handled in the synthesizer's setter).
            Button {
                synthesizer.voiceRepliesEnabled.toggle()
            } label: {
                Image(systemName: synthesizer.voiceRepliesEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.borderless)
            .help(synthesizer.voiceRepliesEnabled ? "Assistant reads replies aloud (tap to mute)" : "Spoken replies muted (tap to unmute)")
            Button {
                startNewChat()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(coordinator.transcript.isEmpty && !coordinator.isRunning && coordinator.lastError == nil)
            .help("Start a new conversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !hasAPIKey {
            ChatNoKeyState(onOpenSettings: openSettings)
        } else {
            transcriptScroll
        }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if coordinator.transcript.isEmpty && !coordinator.isRunning {
                        ChatEmptyState(examples: examplePrompts, cleanupCount: cleanupCount) { prompt in
                            draft = prompt
                            inputFocused = true
                        }
                    } else {
                        ForEach(coordinator.transcript) { item in
                            transcriptRow(item)
                        }
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
            // Let the user push the keyboard away by dragging the transcript, so
            // the (keyboard-covered) tab bar is always reachable again on iOS.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coordinator.transcript.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: coordinator.isRunning) { _, _ in scrollToBottom(proxy) }
            // Follow the streaming text without animating every token.
            .onChange(of: coordinator.streamingText) { _, _ in proxy.scrollTo(bottomID, anchor: .bottom) }
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
        }
    }

    // MARK: Input area (banner + gate + note + bar)

    private var inputArea: some View {
        VStack(spacing: 8) {
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
                Label("Add a category before the assistant can create reminders.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.background)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            micButton

            TextField(speech.isListening ? "Listening…" : "Message the assistant…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .disabled(!hasAPIKey || !hasCategories)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                // Explicit key handling: ↩ and ⌘↩ send, ⇧↩ inserts a newline.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                #if os(iOS)
                // Always-reachable way to drop the software keyboard (which covers
                // the tab bar) so the user can never get stuck in the Assistant.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { inputFocused = false }
                    }
                }
                #endif

            // While dictating, the trailing control cancels (mic-stop sends);
            // otherwise it's the normal send button.
            if speech.isListening {
                Button {
                    speech.cancel()
                    draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel dictation")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
    }

    /// Tap-to-talk mic. Starts/stops dictation; pulses red while listening. Stays
    /// enabled while listening so a second tap can stop+send.
    private var micButton: some View {
        Button {
            toggleDictation()
        } label: {
            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                .font(.title)
                .foregroundStyle(micTint)
                .symbolEffect(.pulse, isActive: speech.isListening)
        }
        .buttonStyle(.plain)
        .disabled(!micEnabled)
        .help(micHelp)
    }

    private var micEnabled: Bool {
        if speech.isListening { return true }
        return hasAPIKey && hasCategories && !coordinator.isRunning && speech.isAvailable
    }

    private var micTint: Color {
        if speech.isListening { return .red }
        return micEnabled ? Color.accentColor : Color.secondary
    }

    private var micHelp: String {
        if !speech.isAvailable { return "Speech recognition isn't available on this device" }
        if speech.isListening { return "Stop and send" }
        return "Dictate a message"
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAPIKey, hasCategories, !coordinator.isRunning, !text.isEmpty else { return }
        // Ensure the mic engine isn't left running once a turn starts (e.g. if the
        // user hit return mid-dictation). The final text is already in `draft`.
        if speech.isListening { speech.cancel() }
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

    /// Tap-to-talk toggle. Starting listening stops any spoken reply first (so the
    /// speaker never feeds back into the mic) and clears the draft; the recognizer
    /// then streams its partial into the field. A second tap (or auto-stop on
    /// silence) finishes → the final transcript auto-sends via `onFinalTranscript`.
    private func toggleDictation() {
        if speech.isListening {
            speech.stop()
        } else {
            synthesizer.stop()
            draft = ""
            speech.start()
        }
    }

    /// Connects the STT auto-send path and the TTS reply hook. Idempotent — safe
    /// to call on every `onAppear`. The final transcript flows through the same
    /// `send()` path as typed input; assistant replies are spoken only when the
    /// turn ends normally (the coordinator's hook never fires for tool status).
    private func wireVoice() {
        speech.onFinalTranscript = { text in
            draft = text
            send()
        }
        coordinator.onAssistantReply = { [synthesizer] reply in
            synthesizer.speak(reply)
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
        for: Reminder.self, Category.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ChatView()
        .environment(ChatCoordinator(modelContainer: container))
        .modelContainer(container)
        .frame(width: 480, height: 640)
}
