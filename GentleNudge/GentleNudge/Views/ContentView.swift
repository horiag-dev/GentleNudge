import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @State private var selectedTab = 0
    @State private var showingAddReminder = false
    @State private var showingOnboarding = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var needsAttentionCount: Int {
        reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            return reminder.isOverdue || reminder.isDueToday || reminder.priority == .urgent
        }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                TodayView()
                    .tabItem {
                        Label("Today", systemImage: "sun.max.fill")
                    }
                    .tag(0)

                AllRemindersView()
                    .tabItem {
                        Label("All", systemImage: "tray.full.fill")
                    }
                    .tag(1)

                CategoriesView()
                    .tabItem {
                        Label("Categories", systemImage: "folder.fill")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }

            // Floating add button
            Button {
                HapticManager.impact(.medium)
                showingAddReminder = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(AppColors.accent)
                            .shadow(color: AppColors.accent.opacity(0.4), radius: 8, y: 4)
                    )
            }
            .offset(y: -30)
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
            // Update badge on launch
            await NotificationService.shared.updateBadgeCount(needsAttentionCount)
            #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Update badge when app becomes active
                Task {
                    await NotificationService.shared.updateBadgeCount(needsAttentionCount)
                }
            }
        }
        .onChange(of: reminders) { _, _ in
            // Update badge when reminders change
            Task {
                await NotificationService.shared.updateBadgeCount(needsAttentionCount)
            }
        }
        #endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
