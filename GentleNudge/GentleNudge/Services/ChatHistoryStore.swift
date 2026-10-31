import Foundation

/// The persisted conversation: the API wire history (so the assistant keeps its
/// context) plus the display transcript (so the cards come back).
struct ChatHistorySnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = ChatHistorySnapshot.currentVersion
    var savedAt: Date
    var wireMessages: [MessageParam]
    var transcript: [TranscriptItem]
}

/// Saves the current chat to a JSON file in Application Support so it survives
/// relaunches. Per-device on purpose: the reminders themselves sync through
/// CloudKit, the conversation about them doesn't need to.
///
/// History is bounded on save: the transcript keeps its newest
/// `maxTranscriptItems`, and the wire history keeps its newest
/// `maxWireMessages`, cut at a user *text* message so a tool_use/tool_result
/// pair is never split.
struct ChatHistoryStore: Sendable {
    static let maxTranscriptItems = 200
    static let maxWireMessages = 60

    let fileURL: URL

    static let shared: ChatHistoryStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ChatHistoryStore(fileURL: base.appendingPathComponent("ChatHistory.json"))
    }()

    func load() -> ChatHistorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ChatHistorySnapshot.self, from: data),
              snapshot.version == ChatHistorySnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Encodes on the caller (cheap) and writes off the main thread.
    func save(wireMessages: [MessageParam], transcript: [TranscriptItem]) {
        let snapshot = ChatHistorySnapshot(
            savedAt: Date(),
            wireMessages: Self.trimmedWire(wireMessages),
            transcript: Array(transcript.suffix(Self.maxTranscriptItems))
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    func clear() {
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keeps at most `maxWireMessages`, starting at a user message that carries
    /// text (a fresh user turn), so the history never opens on a dangling
    /// tool_result. Returns empty if no such boundary exists in the window.
    static func trimmedWire(_ messages: [MessageParam]) -> [MessageParam] {
        guard messages.count > maxWireMessages else { return messages }
        let windowStart = messages.count - maxWireMessages
        guard let start = messages[windowStart...].firstIndex(where: { message in
            message.role == "user" && message.content.contains { block in
                if case .text = block { return true }
                return false
            } && !message.content.contains { block in
                if case .toolResult = block { return true }
                return false
            }
        }) else { return [] }
        return Array(messages[start...])
    }
}
