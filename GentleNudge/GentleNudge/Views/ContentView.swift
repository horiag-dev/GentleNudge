import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var reminders: [Reminder]
    @State private var selectedTab = 0
    @State private var showingAddReminder = false

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
        .task {
            // Perform daily backup on app launch
            do {
                try await BackupService.shared.performDailyBackup(reminders: reminders)
            } catch {
                print("Backup failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
