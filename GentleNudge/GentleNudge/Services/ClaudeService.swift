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
                return "Invalid API key. Please update your Claude API key in Constants.swift"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Claude API"
            case .apiError(let message):
                return "API error: \(message)"
            }
        }
    }

    private func makeRequest(prompt: String, maxTokens: Int = 500) async throws -> String {
        guard Constants.claudeAPIKey != "YOUR_CLAUDE_API_KEY_HERE" else {
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

    func enhanceReminder(title: String, notes: String) async throws -> String {
        let prompt = """
        You are helping to enhance a reminder with useful context. Given this reminder:

        Title: \(title)
        Notes: \(notes.isEmpty ? "(no notes)" : notes)

        Provide a brief, helpful description (2-3 sentences max) that adds context or actionable details to this reminder. Be concise and practical. If the reminder mentions a URL or video, describe what it might be about based on the title.

        Respond with ONLY the enhanced description, no preamble or explanation.
        """

        return try await makeRequest(prompt: prompt)
    }

    func suggestCategory(title: String, notes: String, existingCategories: [String]) async throws -> String {
        let categoriesList = existingCategories.joined(separator: ", ")

        let prompt = """
        You are helping categorize a reminder. Given this reminder:

        Title: \(title)
        Notes: \(notes.isEmpty ? "(no notes)" : notes)

        Available categories: \(categoriesList)

        Which category best fits this reminder? Respond with ONLY the exact category name from the list above, nothing else. If none fit well, respond with the most relevant one.
        """

        let response = try await makeRequest(prompt: prompt)

        // Find the closest matching category
        let lowercaseResponse = response.lowercased()
        for category in existingCategories {
            if lowercaseResponse.contains(category.lowercased()) {
                return category
            }
        }

        // Return the first category as fallback
        return existingCategories.first ?? "Personal"
    }

    func suggestNewCategory(title: String, notes: String) async throws -> (name: String, icon: String) {
        let prompt = """
        You are helping create a new category for a reminder app. Given this reminder:

        Title: \(title)
        Notes: \(notes.isEmpty ? "(no notes)" : notes)

        Suggest a new category that would be useful. Available SF Symbol icons:
        house.fill, briefcase.fill, cart.fill, heart.fill, star.fill, flag.fill, bookmark.fill, tag.fill, folder.fill, car.fill, airplane, gift.fill, phone.fill, envelope.fill, calendar, camera.fill, music.note, fork.knife, leaf.fill, dumbbell.fill

        Respond in this exact format (nothing else):
        NAME: [category name]
        ICON: [sf symbol name]
        """

        let response = try await makeRequest(prompt: prompt)
        let lines = response.components(separatedBy: "\n")

        var name = "Other"
        var icon = "folder.fill"

        for line in lines {
            if line.hasPrefix("NAME:") {
                name = line.replacingOccurrences(of: "NAME:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("ICON:") {
                icon = line.replacingOccurrences(of: "ICON:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        return (name, icon)
    }

    // MARK: - Batch Import Analysis

    struct CategoryAssignment: Sendable {
        let reminderIndex: Int
        let categoryName: String
    }

    func analyzeBatchForCategories(
        reminders: [(title: String, notes: String, listName: String)],
        existingCategories: [String]
    ) async throws -> [CategoryAssignment] {
        // Build a list of reminders for analysis
        var reminderList = ""
        for (index, reminder) in reminders.enumerated() {
            reminderList += "\(index): \(reminder.title)"
            if !reminder.notes.isEmpty {
                reminderList += " (notes: \(reminder.notes.prefix(100)))"
            }
            reminderList += " [from list: \(reminder.listName)]\n"
        }

        let categoriesList = existingCategories.joined(separator: ", ")

        let prompt = """
        You are helping categorize a batch of reminders imported from Apple Reminders.

        Available categories: \(categoriesList)

        Reminders to categorize:
        \(reminderList)

        For each reminder, assign the most appropriate category from the available list.
        Consider the reminder's title, notes, and original list name as hints.

        Respond with ONLY a list in this exact format (one per line, nothing else):
        INDEX:CATEGORY_NAME

        Example:
        0:Work
        1:House
        2:Personal

        Assign categories for all \(reminders.count) reminders.
        """

        let response = try await makeRequest(prompt: prompt, maxTokens: 2000)
        var assignments: [CategoryAssignment] = []

        let lines = response.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let index = Int(parts[0]) else { continue }

            let suggestedCategory = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Match to existing category (case-insensitive)
            let matchedCategory = existingCategories.first { cat in
                cat.lowercased() == suggestedCategory.lowercased()
            } ?? existingCategories.first ?? "Personal"

            assignments.append(CategoryAssignment(reminderIndex: index, categoryName: matchedCategory))
        }

        return assignments
    }

    func suggestCategoriesForImport(
        reminders: [(title: String, notes: String, listName: String)]
    ) async throws -> [String] {
        // Analyze all reminders and suggest what categories would be useful
        var reminderSummary = ""
        for reminder in reminders.prefix(50) { // Limit to avoid token limits
            reminderSummary += "- \(reminder.title) [list: \(reminder.listName)]\n"
        }

        let prompt = """
        Analyze these reminders imported from Apple Reminders and suggest 4-8 useful categories:

        \(reminderSummary)

        Suggest practical category names that would help organize these reminders.
        Keep names short (1-3 words). Include categories like "Urgent Today" and "When There's Time" if appropriate.

        Respond with ONLY the category names, one per line, nothing else.
        """

        let response = try await makeRequest(prompt: prompt, maxTokens: 500)
        let categories = response
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 30 }

        return Array(categories.prefix(8))
    }
}
