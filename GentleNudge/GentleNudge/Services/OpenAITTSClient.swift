import Foundation

// MARK: - Errors

/// Typed failures from the OpenAI speech endpoint. Any of these makes
/// `SpeechSynthesizer` fall back to Apple's `AVSpeechSynthesizer` so the user
/// still hears the reply.
enum OpenAITTSError: Error, LocalizedError, Sendable {
    case notConfigured
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case apiError(status: Int, message: String)
    case emptyAudio
    case network(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The OpenAI API key is not configured."
        case .invalidURL: return "The OpenAI speech URL is invalid."
        case .invalidResponse: return "The OpenAI speech API returned an invalid response."
        case .authenticationFailed: return "The OpenAI API key was rejected."
        case .rateLimited: return "The OpenAI speech API is rate limited."
        case .serverError(let status): return "The OpenAI speech API returned a server error (\(status))."
        case .apiError(let status, let message): return "OpenAI speech API error (\(status)): \(message)"
        case .emptyAudio: return "The OpenAI speech API returned no audio."
        case .network(let message): return "Network error: \(message)"
        case .encoding(let message): return "Encoding error: \(message)"
        }
    }
}

// MARK: - Request wire type

private struct SpeechRequest: Encodable {
    let model: String
    let input: String
    let voice: String
    let instructions: String
    let response_format: String
}

private struct OpenAIErrorBody: Decodable {
    struct Detail: Decodable {
        let message: String?
        let type: String?
    }
    let error: Detail?
}

// MARK: - Client

/// Neural text-to-speech transport for the assistant's spoken replies. Calls
/// OpenAI's `POST /v1/audio/speech` with `gpt-4o-mini-tts` and returns the raw
/// MP3 audio `Data` for playback. Kept off the main actor (its own `URLSession`)
/// so the network round-trip never blocks the UI; validates the HTTP status and
/// throws a typed `OpenAITTSError`. `SpeechSynthesizer` owns retry/fallback.
actor OpenAITTSClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // Short reminder replies: a tight request timeout keeps latency bounded
        // and fails fast to the Apple fallback when the network is slow/offline.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// Synthesizes `text` in `voice` with the given tone `instructions`, returning
    /// binary MP3 audio (`audio/mpeg`). Throws `OpenAITTSError` on any failure.
    func synthesize(text: String, voice: String, instructions: String) async throws -> Data {
        let apiKey = Constants.openAIAPIKey
        guard !apiKey.isEmpty else { throw OpenAITTSError.notConfigured }
        guard let url = URL(string: Constants.openAISpeechURL) else { throw OpenAITTSError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SpeechRequest(
            model: Constants.openAITTSModel,
            input: text,
            voice: voice,
            instructions: instructions,
            response_format: "mp3"
        )
        do {
            urlRequest.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw OpenAITTSError.encoding("Failed to encode request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw OpenAITTSError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAITTSError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw OpenAITTSError.authenticationFailed
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw OpenAITTSError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw OpenAITTSError.serverError(status: http.statusCode)
        default:
            // Error responses are JSON even though a success is binary audio.
            throw OpenAITTSError.apiError(
                status: http.statusCode,
                message: Self.extractMessage(from: data) ?? "Unexpected status"
            )
        }

        guard !data.isEmpty else { throw OpenAITTSError.emptyAudio }
        return data
    }

    private static func extractMessage(from data: Data) -> String? {
        if let body = try? JSONDecoder().decode(OpenAIErrorBody.self, from: data),
           let message = body.error?.message {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}
