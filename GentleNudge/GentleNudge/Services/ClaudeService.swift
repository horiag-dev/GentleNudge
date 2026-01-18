import Foundation

actor ClaudeService {
    static let shared = ClaudeService()

    private init() {}

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct APIRequest: Codable {
        let model: String
        let max_tokens: Int
        let messages: [Message]
    }

    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    struct APIResponse: Codable {
        let content: [ContentBlock]
    }

    enum ClaudeError: LocalizedError {
        case invalidAPIKey
        case networkError(Error)
        case invalidResponse
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey:
                return "Invalid API key. Please add your Claude API key in Settings."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Claude API"
            case .apiError(let message):
                return "API error: \(message)"
            }
        }
    }

    private func makeRequest(prompt: String, maxTokens: Int = 300) async throws -> String {
        guard Constants.isAPIKeyConfigured else {
            throw ClaudeError.invalidAPIKey
        }

        guard let url = URL(string: Constants.claudeAPIURL) else {
            throw ClaudeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let apiRequest = APIRequest(
            model: Constants.claudeModel,
            max_tokens: maxTokens,
            messages: [Message(role: "user", content: prompt)]
        )

        request.httpBody = try JSONEncoder().encode(apiRequest)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.apiError(errorMessage)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let text = apiResponse.content.first?.text else {
            throw ClaudeError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Simple Polish (fix typos, clarify)

    struct PolishedReminder: Sendable {
        let title: String
        let notes: String
        let linkInfo: String? // Only if there was a URL
    }

    /// Polishes a reminder: fixes typos, clarifies title, extracts link info if present
    func polishReminder(title: String, notes: String) async throws -> PolishedReminder {
        // Check if there's a URL in title or notes
        let combinedText = title + " " + notes
        let urlPattern = try? NSRegularExpression(pattern: "https?://[^\\s]+", options: [])
        let hasURL = urlPattern?.firstMatch(in: combinedText, options: [], range: NSRange(combinedText.startIndex..., in: combinedText)) != nil

        let prompt: String
        if hasURL {
            prompt = """
            Polish this reminder and extract info about the link.

            Title: \(title)
            Notes: \(notes.isEmpty ? "(none)" : notes)

            Instructions:
            1. Fix any typos in the title
            2. Make the title clearer if needed (keep it short)
            3. For the URL, briefly describe what it links to (1 sentence max)

            Respond in EXACTLY this format:
            TITLE: [polished title]
            NOTES: [original notes, unchanged - keep any URLs]
            LINK_INFO: [brief description of what the URL is about]
            """
        } else {
            prompt = """
            Polish this reminder.

            Title: \(title)
            Notes: \(notes.isEmpty ? "(none)" : notes)

            Instructions:
            1. Fix any typos in the title
            2. Make the title clearer if needed (keep it short and simple)
            3. Don't change the meaning

            Respond in EXACTLY this format:
            TITLE: [polished title]
            NOTES: [original notes, unchanged]
            """
        }

        let response = try await makeRequest(prompt: prompt)
        let lines = response.components(separatedBy: "\n")

        var polishedTitle = title
        var polishedNotes = notes
        var linkInfo: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("TITLE:") {
                let newTitle = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !newTitle.isEmpty && newTitle.lowercased() != "(none)" {
                    polishedTitle = newTitle
                }
            } else if trimmed.uppercased().hasPrefix("NOTES:") {
                let newNotes = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if newNotes.lowercased() != "(none)" && newNotes.lowercased() != "(unchanged)" {
                    // Keep original notes to preserve URLs exactly
                    polishedNotes = notes
                }
            } else if trimmed.uppercased().hasPrefix("LINK_INFO:") {
                let info = trimmed.dropFirst(10).trimmingCharacters(in: .whitespaces)
                if !info.isEmpty && info.lowercased() != "(none)" {
                    linkInfo = info
                }
            }
        }

        return PolishedReminder(
            title: polishedTitle,
            notes: polishedNotes,
            linkInfo: linkInfo
        )
    }
}
