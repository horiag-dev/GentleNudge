import Foundation
import SwiftData

/// One durable fact the assistant has learned about the user ("Wife is named
/// Sarah.", "Prefers terse replies."), reused across conversations to
/// personalize help. A small curated store — NOT chat history. Synced via
/// CloudKit like every other model, so all stored properties carry defaults
/// (exactly like `Category`).
@Model
final class UserMemory: Identifiable {
    var id: UUID = UUID()
    /// The fact as a concise standalone statement about the user.
    var content: String = ""
    /// Light grouping tag; one of `UserMemory.kinds`. Stored as a String for
    /// CloudKit compatibility; validate/normalize via `normalizedKind(_:)`.
    var kind: String = "other"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        content: String,
        kind: String = "other",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The supported grouping tags, matching the `remember` tool's enum.
    static let kinds = ["family", "preference", "work", "health", "routine", "other"]

    /// Maps any raw kind string onto a supported tag, falling back to "other".
    static func normalizedKind(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kinds.contains(lowered) ? lowered : "other"
    }
}
