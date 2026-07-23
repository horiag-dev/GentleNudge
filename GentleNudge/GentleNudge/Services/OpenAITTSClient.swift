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
/// OpenAI's `POST /v1/audio/speech` with `gpt-4o-mini-tts` two ways:
/// - `streamSynthesize` (preferred): raw PCM chunks as they arrive, so playback
///   can start on the first chunk instead of after the full download.
/// - `synthesize` (fallback): the complete MP3 `Data` in one piece.
///
/// Kept off the main actor (its own `URLSession`) so the network round-trip
/// never blocks the UI; validates the HTTP status and throws a typed
/// `OpenAITTSError`. `SpeechSynthesizer` owns retry/fallback.
actor OpenAITTSClient {
    private let session: URLSession

    /// Target size of each PCM chunk yielded by `streamSynthesize`. The wire
    /// format is 24 kHz mono signed 16-bit PCM = 48,000 bytes/second, so
    /// 9,600 bytes ≈ 200 ms of audio — small enough for smooth incremental
    /// scheduling, large enough to avoid per-buffer churn.
    private static let pcmChunkBytes = 9_600

    /// The first chunk is released at ≈100 ms so speech can begin as soon as
    /// possible; later chunks use the full size.
    private static let firstPCMChunkBytes = 4_800

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
        let urlRequest = try Self.makeRequest(
            text: text, voice: voice, instructions: instructions, responseFormat: "mp3"
        )

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
        guard http.statusCode == 200 else {
            throw Self.statusError(status: http, body: data)
        }

        guard !data.isEmpty else { throw OpenAITTSError.emptyAudio }
        return data
    }

    /// Synthesizes `text` as a live stream of raw PCM chunks (24 kHz, mono,
    /// signed 16-bit little-endian — OpenAI's `response_format: "pcm"`), so the
    /// caller can start playback on the first chunk instead of waiting for the
    /// whole clip.
    ///
    /// The HTTP status is validated BEFORE the stream is returned: a non-200
    /// drains the (small JSON) error body and throws the same typed
    /// `OpenAITTSError` as the buffered path, so callers never have to
    /// distinguish "failed to start" from a bad response. Chunks are yielded at
    /// ≈100 ms first (fast start) and ≈200 ms thereafter; every chunk except
    /// possibly the last is sample-aligned (even byte count). Cancelling the
    /// consuming task cancels the underlying request; the stream then finishes
    /// with `CancellationError`. A 200 that carries no audio at all finishes
    /// with `OpenAITTSError.emptyAudio`.
    func streamSynthesize(
        text: String, voice: String, instructions: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let urlRequest = try Self.makeRequest(
            text: text, voice: voice, instructions: instructions, responseFormat: "pcm"
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAITTSError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw OpenAITTSError.invalidResponse
        }
        guard http.statusCode == 200 else {
            // Error responses are small JSON bodies; drain (capped, defensively)
            // so the typed error can carry the API's message.
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 64_000 { break }
                }
            } catch {
                // The status error below is more useful than a drain failure.
            }
            bytes.task.cancel()
            throw Self.statusError(status: http, body: body)
        }

        return AsyncThrowingStream { continuation in
            let reader = Task {
                var buffer = Data()
                buffer.reserveCapacity(Self.pcmChunkBytes)
                var isFirstChunk = true
                var totalBytes = 0
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        let threshold = isFirstChunk ? Self.firstPCMChunkBytes : Self.pcmChunkBytes
                        if buffer.count >= threshold {
                            totalBytes += buffer.count
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            isFirstChunk = false
                        }
                    }
                    if !buffer.isEmpty {
                        totalBytes += buffer.count
                        continuation.yield(buffer)
                    }
                    if totalBytes == 0 {
                        continuation.finish(throwing: OpenAITTSError.emptyAudio)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: OpenAITTSError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    // MARK: Request building & status mapping (shared by both paths)

    /// Builds the authorized JSON POST for `/v1/audio/speech`.
    private static func makeRequest(
        text: String, voice: String, instructions: String, responseFormat: String
    ) throws -> URLRequest {
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
            response_format: responseFormat
        )
        do {
            urlRequest.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw OpenAITTSError.encoding("Failed to encode request: \(error)")
        }
        return urlRequest
    }

    /// Maps a non-200 response (plus its JSON error body) to a typed error.
    private static func statusError(status http: HTTPURLResponse, body: Data) -> OpenAITTSError {
        switch http.statusCode {
        case 401:
            return .authenticationFailed
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .serverError(status: http.statusCode)
        default:
            // Error responses are JSON even though a success is binary audio.
            return .apiError(
                status: http.statusCode,
                message: extractMessage(from: body) ?? "Unexpected status"
            )
        }
    }

    private static func extractMessage(from data: Data) -> String? {
        if let body = try? JSONDecoder().decode(OpenAIErrorBody.self, from: data),
           let message = body.error?.message {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}
