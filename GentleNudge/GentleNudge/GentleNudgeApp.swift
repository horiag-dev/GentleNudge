import SwiftUI
import SwiftData

enum StorageMode: String {
    case cloudKit = "CloudKit"
    case local = "Local"
    case memory = "Memory (Temporary)"
}

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var storageMode: StorageMode = .local
}

@main
struct GentleNudgeApp: App {
    /// The single shared container, created once at launch.
    let sharedModelContainer: ModelContainer

    /// One `ChatCoordinator` owned **above** navigation (§3.1) so it survives the
    /// macOS detail-column swap and iOS tab changes; injected into `ChatView` via
    /// the environment. It writes through its own `ReminderRepository` over the
    /// shared container.
    @State private var chatCoordinator: ChatCoordinator

    init() {
        // One-time launch migration (alongside the habit-marker backfill below):
        // seed the three-way habit-visibility mode from the legacy boolean.
        Constants.migrateHabitVisibilityIfNeeded()

        let container = Self.makeSharedModelContainer()
        self.sharedModelContainer = container
        _chatCoordinator = State(initialValue: ChatCoordinator(modelContainer: container))
    }

    private static func makeSharedModelContainer() -> ModelContainer {
        let schema = Schema([
            Reminder.self,
            Category.self,
            UserMemory.self,
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

        // Helper to delete corrupted database if needed.
        // Only ever call this as a LAST resort (after the local configuration has
        // also failed) — deleting the store destroys the user's data.
        func deleteLocalStore() {
            let fileManager = FileManager.default
            #if os(macOS)
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                // Remove the store and its SQLite sidecar files
                for suffix in ["default.store", "default.store-shm", "default.store-wal"] {
                    try? fileManager.removeItem(at: appSupport.appendingPathComponent(suffix))
                }
                print("Deleted local store for fresh start")
            }
            #endif
        }

        do {
            // Try CloudKit configuration first
            let container = try ModelContainer(for: schema, configurations: [cloudKitConfig])
            print("Using CloudKit sync with container: iCloud.com.horiag.GentleNudge")
            AppState.shared.storageMode = .cloudKit

            // Initialize default categories on first launch
            // Use UserDefaults to track if THIS device has already set up defaults
            // This prevents duplicates when CloudKit syncs from other devices
            Task { @MainActor in
                let context = container.mainContext

                let hasCreatedDefaults = UserDefaults.standard.bool(forKey: "hasCreatedDefaultCategories")
                if !hasCreatedDefaults {
                    // Wait a moment for CloudKit to sync
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                    let descriptor = FetchDescriptor<Category>()

                    // Only create defaults if the store is VERIFIED empty after
                    // the sync delay. A throwing fetch must NOT seed — we can't
                    // tell "empty" from "unreadable", and seeding blind is what
                    // duplicates every category on a second device.
                    if let existingCategories = try? context.fetch(descriptor),
                       existingCategories.isEmpty {
                        for defaultCategory in Category.defaults {
                            context.insert(defaultCategory)
                        }
                        try? context.save()
                    }

                    UserDefaults.standard.set(true, forKey: "hasCreatedDefaultCategories")
                }

                // One-time backfill: mark a pre-existing "Habits" category so habit
                // identity keys off the stable marker instead of a name match.
                // Runs even for stores seeded before isHabitCategory existed.
                Category.backfillHabitMarker(in: context)

                // Self-heal duplicate categories (a second device seeding before
                // CloudKit's first import lands, or an interrupted import): merge
                // same-named categories into one, reparenting every reminder onto
                // the survivor. Idempotent — a no-op on a clean store.
                Category.cleanDuplicates(in: context)
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

            // Fall back to local storage WITHOUT deleting the store first — a
            // CloudKit init failure (entitlements, account issues) doesn't mean
            // the local data is corrupted, and deleting it would lose user data.
            func makeLocalContainer() throws -> ModelContainer {
                let container = try ModelContainer(for: schema, configurations: [localConfig])
                print("Using local storage (CloudKit unavailable)")
                AppState.shared.storageMode = .local

                Task { @MainActor in
                    let context = container.mainContext

                    let hasCreatedDefaults = UserDefaults.standard.bool(forKey: "hasCreatedDefaultCategories")
                    if !hasCreatedDefaults {
                        let descriptor = FetchDescriptor<Category>()

                        // Seed only when the store is VERIFIED empty — a throwing
                        // fetch must not seed (same rule as the CloudKit path).
                        if let existingCategories = try? context.fetch(descriptor),
                           existingCategories.isEmpty {
                            for defaultCategory in Category.defaults {
                                context.insert(defaultCategory)
                            }
                            try? context.save()
                        }

                        UserDefaults.standard.set(true, forKey: "hasCreatedDefaultCategories")
                    }

                    // One-time backfill: mark a pre-existing "Habits" category
                    // (stores seeded before isHabitCategory existed). Idempotent.
                    Category.backfillHabitMarker(in: context)

                    // Merge any duplicate categories left by an earlier double
                    // seed, reparenting reminders onto the survivor. Idempotent.
                    Category.cleanDuplicates(in: context)
                }

                return container
            }

            do {
                return try makeLocalContainer()
            } catch {
                // The store itself may be corrupted or unmigratable — delete it
                // as a last resort and retry once with a fresh store.
                print("Local storage failed: \(error)")
                deleteLocalStore()

                do {
                    return try makeLocalContainer()
                } catch {
                    // Last resort: in-memory storage
                    print("Local storage failed after reset: \(error)")
                    print("Falling back to in-memory storage (data will not persist)")

                    let memoryConfig = ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: true
                    )

                    do {
                        let container = try ModelContainer(for: schema, configurations: [memoryConfig])
                        AppState.shared.storageMode = .memory

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
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(macOS)
                MacContentView()
                    .frame(minWidth: 800, minHeight: 500)
                #else
                ContentView()
                #endif
            }
            .environment(chatCoordinator)
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
