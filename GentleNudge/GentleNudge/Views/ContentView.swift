import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @State private var selectedTab = 0
    @State private var showingAddReminder = false
    @State private var showingOnboarding = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "sparkles")
                }
                .tag(0)

            // Empty view for "New" tab - triggers sheet via onChange
            Color.clear
                .tabItem {
                    Label("New", systemImage: "plus.app.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 1 {
                // "New" tab selected - show add sheet and return to previous tab
                HapticManager.impact(.light)
                showingAddReminder = true
                // Return to Today tab
                selectedTab = 0
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
                // Update scheduled notification when app goes to background
                // Use TOMORROW's data since the notification fires tomorrow morning
                NotificationService.shared.updateScheduledNotificationContent(
                    needsAttentionCount: tomorrowNeedsAttentionCount,
                    topItems: tomorrowTopItemTitles
                )
            }
        }
        .onChange(of: reminders) { _, _ in
            // Update badge and scheduled notification when reminders change
            Task {
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
