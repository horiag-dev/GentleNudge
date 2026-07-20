import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @State private var selectedTab = 0
    /// The last non-pseudo tab, so tapping "New" returns here instead of a
    /// hard-coded 0 (Today=0, Assistant=1, Settings=3 are real; New=2 is a sheet).
    @State private var lastRealTab = 0
    @State private var showingAddReminder = false
    @State private var showingOnboarding = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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

    // For scheduling tomorrow's notification - what will need attention tomorrow?
    private var tomorrowNeedsAttentionItems: [Reminder] {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!

        return reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            guard let dueDate = reminder.dueDate else { return false }

            // Will be overdue tomorrow (due before tomorrow) or due tomorrow
            let dueDay = calendar.startOfDay(for: dueDate)
            return dueDay <= tomorrow
        }
    }

    private var tomorrowNeedsAttentionCount: Int {
        tomorrowNeedsAttentionItems.count
    }

    private var tomorrowTopItemTitles: [String] {
        Array(tomorrowNeedsAttentionItems.prefix(5).map { $0.title })
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
                .tabItem {
                    Label("Today", systemImage: "checklist")
                }
                .tag(0)

            ChatView(onOpenSettings: { selectedTab = 3 })
                .tabItem {
                    Label("Assistant", systemImage: "sparkles")
                }
                .tag(1)

            // Empty view for "New" tab - triggers sheet via onChange
            Color.clear
                .tabItem {
                    Label("New", systemImage: "plus.app.fill")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 2 {
                // "New" is a pseudo-tab: show the add sheet and bounce back to the
                // last real tab (not a hard-coded 0).
                HapticManager.impact(.light)
                showingAddReminder = true
                selectedTab = lastRealTab
            } else {
                // Remember the most recent real tab (0 / 1 / 3).
                lastRealTab = newTab
            }
        }
        .sheet(isPresented: $showingAddReminder) {
            AddReminderView()
        }
        #if os(iOS)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView()
        }
        .onAppear {
            // Show onboarding for first-time users
            if !hasCompletedOnboarding {
                showingOnboarding = true
            }
        }
        #endif
        .task {
            // Perform daily backup on app launch
            do {
                try await BackupService.shared.performDailyBackup(reminders: reminders)
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
                // Update scheduled notification when app goes to background.
                // Use TOMORROW's data since the notification fires tomorrow morning.
                // This pre-generates an AI-prioritized body inside a background-task
                // window and always schedules the non-AI fallback first, so the
                // notification is never empty or worse than today.
                NotificationService.shared.preGenerateAndScheduleMorningNotification(
                    needsAttentionCount: tomorrowNeedsAttentionCount,
                    topItems: tomorrowTopItemTitles,
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

#Preview {
    ContentView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
