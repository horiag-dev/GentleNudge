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

    /// Settings deep link: iOS switches to the Settings tab; macOS opens the
    /// settings sheet. Nil in previews.
    var onOpenSettings: (() -> Void)?

    @State private var draft = ""
    @State private var hasAPIKey = Constants.isAPIKeyConfigured
    @State private var approvalPresenter = CategoryApprovalPresenter()
    @FocusState private var inputFocused: Bool

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
            wireApprovalHook()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshKeyState() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
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
                        ChatEmptyState(examples: examplePrompts) { prompt in
                            draft = prompt
                            inputFocused = true
                        }
                    } else {
                        ForEach(coordinator.transcript) { item in
                            transcriptRow(item)
                        }
                    }

                    if coordinator.isRunning {
                        ChatToolStatusRow()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: coordinator.transcript.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: coordinator.isRunning) { _, _ in scrollToBottom(proxy) }
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

            if let pending = approvalPresenter.pending {
                CategoryApprovalCard(
                    name: pending.name,
                    onApprove: { approvalPresenter.resolve(true) },
                    onCancel: { approvalPresenter.resolve(false) }
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
            TextField("Message the assistant…", text: $draft, axis: .vertical)
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

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAPIKey, hasCategories, !coordinator.isRunning, !text.isEmpty else { return }
        coordinator.run(userText: text)
        draft = ""
        inputFocused = true
    }

    private func startNewChat() {
        // Unblock any pending category gate so a stale continuation can't leak.
        approvalPresenter.resolve(false)
        coordinator.newChat()
        draft = ""
        inputFocused = true
    }

    private func openSettings() {
        onOpenSettings?()
    }

    private func refreshKeyState() {
        hasAPIKey = Constants.isAPIKeyConfigured
    }

    /// Replace the coordinator's default-deny stub with the in-chat gate.
    private func wireApprovalHook() {
        let presenter = approvalPresenter
        coordinator.categoryApprovalHook = { name in
            await presenter.request(name: name)
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
