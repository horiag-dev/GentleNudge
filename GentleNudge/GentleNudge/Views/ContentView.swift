import SwiftUI
import SwiftData
import Combine
#if os(iOS)
import UIKit
#endif

/// The iOS root. Three real destinations — Today, Assistant, Settings — behind a
/// custom bottom bar that puts the two AI capture methods first:
///
/// - **Voice** is a normal tab-sized item that stands out via an always-on
///   distinct color (purple, reading "AI") rather than by size. It launches the
///   hands-free `VoiceModeView` full screen. It is not a tab; it presents over
///   whatever is selected.
/// - **Assistant** (text AI) stays a first-class tab beside Today.
/// - **Manual entry** is deliberately demoted: the old "New" pseudo-tab is gone,
///   replaced by a "+" in the Today header (`TodayView`), since hand-entry is
///   the rare path.
///
/// The native `TabView` is kept underneath (hidden system bar) so tab lifecycle
/// and state preservation behave exactly as before.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChatCoordinator.self) private var coordinator
    @Query private var reminders: [Reminder]

    /// Today = 0, Assistant = 1, Settings = 2. (Voice is not a tab.)
    @State private var selectedTab = 0

    /// Bumped whenever the Assistant tab becomes active so `ChatView` can raise
    /// the keyboard. Driven from here (not `ChatView.onAppear`) because a
    /// `TabView` doesn't reliably re-fire a child's `onAppear` on every switch.
    @State private var assistantFocusTrigger = 0

    /// Per-launch dismissal of the in-memory data-loss banner (deliberately not
    /// persisted — the warning must return on every launch while it applies).
    @State private var storageWarningDismissed = false

    /// The one TTS engine, owned at the root (it used to live in `ChatView`) so
    /// the promoted Voice entry can hand it to `VoiceModeView`: mute state and
    /// the OpenAI-vs-Apple routing stay global, and only one engine ever speaks.
    @State private var synthesizer = SpeechSynthesizer()
    @State private var showingVoiceMode = false

    #if os(iOS)
    /// Mirrors native behavior under the keyboard: the system tab bar sits
    /// behind the keyboard, so the custom bar hides while typing.
    @State private var keyboardVisible = false
    #endif

    @State private var notificationUpdateTask: Task<Void, Never>?

    private var needsAttentionItems: [Reminder] {
        reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            // Only overdue or due today (not urgent-only items)
            return reminder.isOverdue || reminder.isDueToday
        }
    }

    private var needsAttentionCount: Int {
        needsAttentionItems.count
    }

    private var topItemTitles: [String] {
        Array(needsAttentionItems.prefix(5).map { $0.title })
    }

    // For scheduling the morning notification: what will need attention on the
    // day it actually fires (still today when the app is backgrounded before
    // the alert time, tomorrow otherwise)?
    private func needsAttentionItems(asOf day: Date) -> [Reminder] {
        let calendar = Calendar.current
        let referenceDay = calendar.startOfDay(for: day)

        return reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            guard let dueDate = reminder.dueDate else { return false }

            // Will be overdue (due before that day) or due that day
            return calendar.startOfDay(for: dueDate) <= referenceDay
        }
    }

    /// Lightweight, Sendable snapshots of every reminder for off-main
    /// briefing generation (the service selects the candidates itself).
    private var reminderSummaries: [MorningBriefingService.ReminderSummary] {
        reminders.map {
            MorningBriefingService.ReminderSummary(
                title: $0.title,
                categoryName: $0.category?.name,
                dueDate: $0.dueDate,
                isHabit: $0.isHabit,
                isCompleted: $0.isCompleted
            )
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .hidesNativeTabBar()
                .tag(0)

            ChatView(focusTrigger: assistantFocusTrigger, onOpenSettings: { selectedTab = 2 })
                .hidesNativeTabBar()
                .tag(1)

            SettingsView()
                .hidesNativeTabBar()
                .tag(2)
        }
        // Arriving on the Assistant tab pops the keyboard: bump the trigger the
        // ChatView observes. ChatView itself gates on can-type (key + category)
        // and defers the focus set so it reliably raises the keyboard.
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 1 { assistantFocusTrigger += 1 }
        }
        // In-memory fallback = silent data loss. A Settings row alone isn't a
        // signal anyone sees, so surface a persistent (dismissible-per-launch)
        // banner above whatever tab is showing. The storage mode is fixed at
        // launch, so a plain read is enough.
        .safeAreaInset(edge: .top, spacing: 0) {
            if AppState.shared.storageMode == .memory && !storageWarningDismissed {
                StorageWarningBanner(dismissed: $storageWarningDismissed)
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                bottomBar
            }
        }
        // Voice gets the app-level coordinator (same conversation as typed chat)
        // and the root-owned synthesizer, exactly as it did when launched from
        // inside the Assistant — only the entry point moved.
        .fullScreenCover(isPresented: $showingVoiceMode) {
            VoiceModeView(synthesizer: synthesizer, onOpenSettings: { selectedTab = 2 })
                .environment(coordinator)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = false }
        }
        #endif
        .task {
            // Perform daily backup on app launch. Snapshot the @Model fields on
            // the main actor FIRST — the backup actor must never touch live
            // models (or their category relationship) off the main thread.
            let backupSnapshots = reminders.map(BackupService.ReminderBackupSnapshot.init)
            do {
                try await BackupService.shared.performDailyBackup(reminders: backupSnapshots)
            } catch {
                print("Backup failed: \(error.localizedDescription)")
            }

            #if os(iOS)
            // Update badge and scheduled notification content on launch
            await NotificationService.shared.updateBadgeCount(needsAttentionCount)
            NotificationService.shared.updateScheduledNotificationContent(
                needsAttentionCount: needsAttentionCount,
                topItems: topItemTitles
            )
            #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Update badge and scheduled notification when app becomes active
                Task {
                    await NotificationService.shared.updateBadgeCount(needsAttentionCount)
                    NotificationService.shared.updateScheduledNotificationContent(
                        needsAttentionCount: needsAttentionCount,
                        topItems: topItemTitles
                    )
                }
            } else if newPhase == .background {
                // Safety net for the custom bar: if iOS tears the keyboard down
                // during backgrounding without a `keyboardWillHide`, a stale
                // `keyboardVisible == true` would leave the bar hidden forever.
                // Reset here — if the keyboard restores on return, its
                // `keyboardWillShow` re-fires and hides the bar again.
                keyboardVisible = false
                // Update scheduled notification when app goes to background.
                // Use the data for the day the notification will actually fire —
                // still TODAY when backgrounding before the alert time, tomorrow
                // otherwise (a repeating calendar trigger fires at the NEXT
                // occurrence of its hour/minute). This pre-generates an
                // AI-prioritized body inside a background-task window and always
                // schedules the non-AI fallback first, so the notification is
                // never empty or worse than today.
                let fireDay = NotificationService.shared.nextMorningFireDay
                let fireDayItems = needsAttentionItems(asOf: fireDay)
                NotificationService.shared.preGenerateAndScheduleMorningNotification(
                    needsAttentionCount: fireDayItems.count,
                    topItems: Array(fireDayItems.prefix(5).map { $0.title }),
                    reminders: reminderSummaries
                )
            }
        }
        .onChange(of: reminders) { _, _ in
            // Debounce notification updates — avoid redundant work on rapid changes
            notificationUpdateTask?.cancel()
            notificationUpdateTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
                guard !Task.isCancelled else { return }
                await NotificationService.shared.updateBadgeCount(needsAttentionCount)
                NotificationService.shared.updateScheduledNotificationContent(
                    needsAttentionCount: needsAttentionCount,
                    topItems: topItemTitles
                )
            }
        }
        #endif
    }
}

// MARK: - Custom bottom bar (iOS)

#if os(iOS)
private extension ContentView {
    /// Four equal slots — Today · Assistant · Voice · Settings — on a standard
    /// bar material with a hairline on top. Every slot keeps the compact native
    /// tab look; Voice stands out via an always-on distinct color, not by size.
    var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            tabButton(0, "Today", "checklist")
            tabButton(1, "Assistant", "sparkles")
            voiceButton
            tabButton(2, "Settings", "gearshape.fill")
        }
        .padding(.top, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.xs)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    func tabButton(_ tag: Int, _ title: String, _ icon: String) -> some View {
        Button {
            selectedTab = tag
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selectedTab == tag ? AppColors.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selectedTab == tag ? .isSelected : [])
    }

    /// The Voice entry: a normal tab-sized item (matching `tabButton`'s icon +
    /// caption layout) that starts a hands-free conversation immediately. It
    /// stands apart from the other tabs — gray when unselected, accent when
    /// selected — with an always-on distinct purple tint that reads as the
    /// special "AI" action. `VoiceModeView` itself handles the no-API-key state
    /// with a Settings hint, so the button is always enabled.
    var voiceButton: some View {
        Button {
            HapticManager.impact(.medium)
            showingVoiceMode = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 24)
                Text("Voice")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.purple)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice")
        .accessibilityHint("Starts a hands-free voice conversation with the assistant")
    }
}
#endif

// MARK: - Storage warning banner (shared iOS + macOS)

/// Persistent warning shown at the top of the main content whenever the store
/// fell back to in-memory storage (`AppState.shared.storageMode == .memory`):
/// nothing done this launch survives a quit, and the only other signal was a
/// buried Settings row. Dismissible per launch via the bound flag; the caller
/// gates on the storage mode so this never renders in normal operation.
struct StorageWarningBanner: View {
    @Binding var dismissed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text("Data isn't being saved — changes will be lost when you quit.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { dismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss for this launch")
            .accessibilityLabel("Dismiss warning")
        }
        .padding(.horizontal, Constants.Spacing.md)
        .padding(.vertical, Constants.Spacing.sm)
        .frame(maxWidth: .infinity)
        .background(Color.red)
    }
}

extension View {
    /// Hides the native tab bar (replaced by the custom bar above). Applied both
    /// at the tab-child level and inside each tab's `NavigationStack` root, since
    /// the preference must reach the enclosing `TabView` from the navigation
    /// content. Cross-platform no-op on macOS, where `ContentView` isn't used
    /// and the `.tabBar` placement doesn't exist.
    @ViewBuilder
    func hidesNativeTabBar() -> some View {
        #if os(iOS)
        self.toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Reminder.self, Category.self, UserMemory.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ContentView()
        .environment(ChatCoordinator(modelContainer: container))
        .modelContainer(container)
}
