import Foundation

// MARK: - JSON value

/// A minimal, round-trippable JSON value. Used both to carry arbitrary
/// `tool_use.input` payloads across the wire unchanged and to build strict
/// tool `input_schema` definitions programmatically.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Convenience accessors

    /// The wrapped string, or nil for any other case (including `.null`).
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The wrapped integer. Accepts an integral `.double` as well.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }
}

// MARK: - Errors

enum AnthropicError: Error, Sendable, LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case badRequest(message: String)
    case apiError(status: Int, message: String)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The Claude API key is not configured."
        case .invalidURL: return "The Claude API URL is invalid."
        case .invalidResponse: return "The Claude API returned an invalid response."
        case .authenticationFailed: return "The Claude API key was rejected."
        case .rateLimited: return "The Claude API is rate limited."
        case .serverError(let status): return "The Claude API returned a server error (\(status))."
        case .badRequest(let message): return "Bad request: \(message)"
        case .apiError(let status, let message): return "API error (\(status)): \(message)"
        case .network(let message): return "Network error: \(message)"
        case .decoding(let message): return "Decoding error: \(message)"
        }
    }
}

// MARK: - Request wire types

struct MessagesRequest: Encodable, Sendable {
    let model: String
    let max_tokens: Int
    let system: [SystemBlock]
    let messages: [MessageParam]
    let tools: [ToolDefinition]
    let tool_choice: ToolChoice?
    let output_config: OutputConfig
    let thinking: ThinkingConfig
}

struct OutputConfig: Encodable, Sendable {
    let effort: String
}

/// `{"type":"disabled"}` by default. We never send `{"type":"enabled", budget_tokens:N}`
/// (400 on Opus 4.8 / Sonnet 5) and never send `temperature`/`top_p`/`top_k`.
struct ThinkingConfig: Encodable, Sendable {
    let type: String
}

struct ToolChoice: Encodable, Sendable {
    let type: String
    let name: String?
}

struct ToolDefinition: Encodable, Sendable {
    let name: String
    let description: String
    let strict: Bool
    let input_schema: JSONValue
}

struct CacheControl: Encodable, Sendable {
    let type = "ephemeral"
}

struct SystemBlock: Encodable, Sendable {
    let type = "text"
    let text: String
    let cache_control: CacheControl?
}

struct MessageParam: Encodable, Sendable {
    let role: String
    let content: [ContentBlockParam]
}

/// Content blocks we send on the wire. Also the shape we re-encode when replaying
/// wire history each turn (text + tool_use echoed from the assistant, tool_result
/// produced by executors).
enum ContentBlockParam: Encodable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case tool_use_id, content, is_error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .tool_use_id)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .is_error)
        }
    }
}

// MARK: - Response wire types

struct MessagesResponse: Decodable, Sendable {
    let id: String?
    let role: String?
    let content: [ResponseContentBlock]
    let stop_reason: String?
    let usage: Usage?
}

struct Usage: Decodable, Sendable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

/// Decodes the response content blocks we understand, and tolerates any unknown
/// block type (e.g. `thinking`) rather than failing the whole response.
enum ResponseContentBlock: Decodable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case other(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
        switch type {
        case "text":
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        case "tool_use":
            let id = (try? container.decode(String.self, forKey: .id)) ?? ""
            let name = (try? container.decode(String.self, forKey: .name)) ?? ""
            let input = (try? container.decode(JSONValue.self, forKey: .input)) ?? .object([:])
            self = .toolUse(id: id, name: name, input: input)
        default:
            self = .other(type: type)
        }
    }

    /// The equivalent wire param, or nil for blocks we cannot re-encode (unknown types).
    var asParam: ContentBlockParam? {
        switch self {
        case .text(let text): return .text(text)
        case .toolUse(let id, let name, let input): return .toolUse(id: id, name: name, input: input)
        case .other: return nil
        }
    }
}

extension MessagesResponse {
    /// Concatenated text of all `text` blocks, trimmed.
    var textContent: String {
        content
            .compactMap { block -> String? in
                if case let .text(text) = block { return text }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All `tool_use` blocks in document order.
    var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            if case let .toolUse(id, name, input) = block { return (id, name, input) }
            return nil
        }
    }
}

private struct APIErrorBody: Decodable {
    struct Detail: Decodable {
        let type: String?
        let message: String?
    }
    let error: Detail?
}

// MARK: - Client

/// Non-streaming transport for the Anthropic Messages API, kept off the main
/// actor. Owns its own `URLSession`. Streaming is deferred to a later increment.
actor AnthropicClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        guard Constants.isAPIKeyConfigured else { throw AnthropicError.notConfigured }
        guard let url = URL(string: Constants.claudeAPIURL) else { throw AnthropicError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(Constants.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw AnthropicError.decoding("Failed to encode request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AnthropicError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }

        // Validate the HTTP status before attempting to decode the body.
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw AnthropicError.authenticationFailed
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicError.rateLimited(retryAfter: retryAfter)
        case 400:
            throw AnthropicError.badRequest(message: Self.extractMessage(from: data) ?? "Bad request")
        case 500...599:
            throw AnthropicError.serverError(status: http.statusCode)
        default:
            throw AnthropicError.apiError(
                status: http.statusCode,
                message: Self.extractMessage(from: data) ?? "Unexpected status"
            )
        }

        do {
            return try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw AnthropicError.decoding("Failed to decode response: \(error)")
        }
    }

    private static func extractMessage(from data: Data) -> String? {
        if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = body.error?.message {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}
