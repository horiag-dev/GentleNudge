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

    private func makeRequest(prompt: String, maxTokens: Int = 500) async throws -> String {
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

    struct EnhancedReminder: Sendable {
        let title: String
        let notes: String
        let category: String
        let context: String
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

    func enhanceReminderFull(title: String, notes: String, existingCategories: [String]) async throws -> EnhancedReminder {
        let categoriesList = existingCategories.joined(separator: ", ")

        let prompt = """
        You are helping enhance a reminder. Given this reminder:

        Title: \(title)
        Notes: \(notes.isEmpty ? "(no notes)" : notes)

        Available categories: \(categoriesList)

        Please enhance this reminder by:
        1. Improving the title if needed (make it clearer/more actionable, but keep it concise)
        2. Adding helpful notes - IMPORTANT: If the notes contain any URLs, you MUST preserve them exactly. Add context around the URL but never remove or modify URLs.
        3. Selecting the best category from the list
        4. Providing a brief AI context (1-2 sentences of helpful background, e.g. what a URL/video is about)

        Respond in this EXACT format with no extra text:
        TITLE: [improved title or original if already good]
        NOTES: [enhanced notes - MUST include any original URLs]
        CATEGORY: [exact category name from the list]
        CONTEXT: [brief helpful context]
        """

        let response = try await makeRequest(prompt: prompt, maxTokens: 500)
        let lines = response.components(separatedBy: "\n")

        var enhancedTitle = title
        var enhancedNotes = notes
        var category = existingCategories.first ?? "Misc"
        var context = ""

        // Extract URLs from original notes to ensure they're preserved
        let urlPattern = try? NSRegularExpression(pattern: "https?://[^\\s]+", options: [])
        let originalURLs = urlPattern?.matches(in: notes, options: [], range: NSRange(notes.startIndex..., in: notes))
            .compactMap { Range($0.range, in: notes).map { String(notes[$0]) } } ?? []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("TITLE:") {
                enhancedTitle = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("NOTES:") {
                var notesValue = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !notesValue.isEmpty && notesValue.lowercased() != "(no notes)" {
                    // Ensure all original URLs are preserved
                    for url in originalURLs {
                        if !notesValue.contains(url) {
                            notesValue = notesValue + "\n" + url
                        }
                    }
                    enhancedNotes = notesValue
                }
            } else if trimmed.uppercased().hasPrefix("CATEGORY:") {
                let suggestedCat = trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)
                // Match to existing category
                if let match = existingCategories.first(where: { $0.lowercased() == suggestedCat.lowercased() }) {
                    category = match
                }
            } else if trimmed.uppercased().hasPrefix("CONTEXT:") {
                context = trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)
            }
        }

        return EnhancedReminder(
            title: enhancedTitle.isEmpty ? title : enhancedTitle,
            notes: enhancedNotes,
            category: category,
            context: context
        )
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

    // MARK: - Batch Enhancement

    struct BatchEnhancedReminder: Sendable {
        let index: Int
        let title: String
        let notes: String
        let category: String
        let context: String
    }

    func enhanceBatchFull(
        reminders: [(title: String, notes: String)],
        existingCategories: [String]
    ) async throws -> [BatchEnhancedReminder] {
        guard !reminders.isEmpty else { return [] }

        // Build reminder list for the prompt
        var reminderList = ""
        for (index, reminder) in reminders.enumerated() {
            reminderList += "[\(index)] Title: \(reminder.title)"
            if !reminder.notes.isEmpty {
                reminderList += "\n    Notes: \(reminder.notes.prefix(200))"
            }
            reminderList += "\n"
        }

        let categoriesList = existingCategories.joined(separator: ", ")

        let prompt = """
        You are enhancing a batch of reminders. For each reminder:
        1. Improve the title if needed (clearer/more actionable, but concise)
        2. Enhance notes - IMPORTANT: preserve any URLs exactly as they appear
        3. Select the best category from: \(categoriesList)
        4. Add brief context (1 sentence of helpful background)

        Reminders to enhance:
        \(reminderList)

        Respond in this EXACT format for each reminder (no extra text):
        [INDEX]
        TITLE: improved title
        NOTES: enhanced notes (keep any URLs)
        CATEGORY: category name
        CONTEXT: brief context

        Enhance all \(reminders.count) reminders.
        """

        let response = try await makeRequest(prompt: prompt, maxTokens: 3000)
        var results: [BatchEnhancedReminder] = []

        // Parse response - split by [INDEX] markers
        let blocks = response.components(separatedBy: "[")
        for block in blocks {
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Extract index from start of block
            let lines = block.components(separatedBy: "\n")
            guard let firstLine = lines.first,
                  let indexEnd = firstLine.firstIndex(of: "]"),
                  let index = Int(firstLine[..<indexEnd]) else { continue }

            var title = ""
            var notes = ""
            var category = existingCategories.first ?? "Misc"
            var context = ""

            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.uppercased().hasPrefix("TITLE:") {
                    title = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if trimmed.uppercased().hasPrefix("NOTES:") {
                    notes = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if trimmed.uppercased().hasPrefix("CATEGORY:") {
                    let suggested = trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)
                    if let match = existingCategories.first(where: { $0.lowercased() == suggested.lowercased() }) {
                        category = match
                    }
                } else if trimmed.uppercased().hasPrefix("CONTEXT:") {
                    context = trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)
                }
            }

            // Preserve original URLs if they got lost
            if index < reminders.count {
                let originalNotes = reminders[index].notes
                let urlPattern = try? NSRegularExpression(pattern: "https?://[^\\s]+", options: [])
                let originalURLs = urlPattern?.matches(in: originalNotes, options: [], range: NSRange(originalNotes.startIndex..., in: originalNotes))
                    .compactMap { Range($0.range, in: originalNotes).map { String(originalNotes[$0]) } } ?? []

                for url in originalURLs {
                    if !notes.contains(url) {
                        notes = notes.isEmpty ? url : notes + "\n" + url
                    }
                }

                results.append(BatchEnhancedReminder(
                    index: index,
                    title: title.isEmpty ? reminders[index].title : title,
                    notes: notes.isEmpty ? originalNotes : notes,
                    category: category,
                    context: context
                ))
            }
        }

        return results
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
