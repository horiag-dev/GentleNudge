import AppIntents
import Foundation

/// "Hey Siri, add to Gentle Nudge" / Shortcuts / Spotlight: hands free text —
/// one todo or a whole list — to the same assistant the chat uses. Runs in the
/// background without opening the app; the coordinator is the app's single
/// instance, registered with `AppDependencyManager` at launch.
///
/// For the share sheet, a Shortcut ("Receive text from Share Sheet" → "Add to
/// Gentle Nudge") exposes this from Mail, Notes, Safari, etc.
struct AddToGentleNudgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Gentle Nudge"
    static let description = IntentDescription(
        "Tell the Gentle Nudge assistant what to add — a single todo or a whole list. It files each one into the right category with dates."
    )

    @Parameter(
        title: "What to add",
        inputOptions: String.IntentInputOptions(multiline: true),
        requestValueDialog: IntentDialog("What should I add?")
    )
    var text: String

    @Dependency private var coordinator: ChatCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Gentle Nudge")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "There was nothing to add.")
        }
        guard Constants.isAPIKeyConfigured else {
            return .result(dialog: "The assistant isn't set up yet. Add your Claude API key in Gentle Nudge's Settings.")
        }
        let reply = await coordinator.runHeadless(userText: trimmed)
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

struct GentleNudgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToGentleNudgeIntent(),
            phrases: [
                "Add to \(.applicationName)",
                "Add a reminder in \(.applicationName)",
                "Tell \(.applicationName) something",
                "Nudge me with \(.applicationName)"
            ],
            shortTitle: "Add to Gentle Nudge",
            systemImageName: "sparkles"
        )
    }
}
