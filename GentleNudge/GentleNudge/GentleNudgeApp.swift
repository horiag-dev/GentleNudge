import SwiftUI
import SwiftData

@main
struct GentleNudgeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Reminder.self,
            Category.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Initialize default categories on first launch
            Task { @MainActor in
                let context = container.mainContext
                let descriptor = FetchDescriptor<Category>()
                let existingCategories = try? context.fetch(descriptor)

                if existingCategories?.isEmpty ?? true {
                    for defaultCategory in Category.defaults {
                        context.insert(defaultCategory)
                    }
                    try? context.save()
                }
            }

            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
