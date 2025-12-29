import SwiftUI
import SwiftData

@main
struct GentleNudgeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Reminder.self,
            Category.self,
        ])

        // Try CloudKit first, fall back to local storage if not configured
        // Use explicit container identifier
        let cloudKitConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.horiag.GentleNudge")
        )

        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            // Try CloudKit configuration first
            let container = try ModelContainer(for: schema, configurations: [cloudKitConfig])
            print("Using CloudKit sync")

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
            // CloudKit failed, use local storage
            print("CloudKit not available, using local storage: \(error)")
            print("Full error details: \(String(describing: error))")
            if let nsError = error as NSError? {
                print("NSError domain: \(nsError.domain), code: \(nsError.code)")
                print("NSError userInfo: \(nsError.userInfo)")
            }
            do {
                let container = try ModelContainer(for: schema, configurations: [localConfig])
                print("Using local storage")

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
                // Last resort: in-memory storage
                print("Local storage failed: \(error)")
                print("Falling back to in-memory storage (data will not persist)")

                let memoryConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )

                do {
                    let container = try ModelContainer(for: schema, configurations: [memoryConfig])

                    Task { @MainActor in
                        let context = container.mainContext
                        for defaultCategory in Category.defaults {
                            context.insert(defaultCategory)
                        }
                        try? context.save()
                    }

                    return container
                } catch {
                    fatalError("Could not create any ModelContainer: \(error)")
                }
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .frame(minWidth: 800, minHeight: 500)
            #else
            ContentView()
            #endif
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
