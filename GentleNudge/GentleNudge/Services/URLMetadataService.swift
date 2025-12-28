import Foundation
import LinkPresentation

actor URLMetadataService {
    static let shared = URLMetadataService()

    private var cache: [URL: LinkMetadata] = [:]

    private init() {}

    struct LinkMetadata: Sendable {
        let title: String?
        let description: String?
        let imageURL: URL?
    }

    func fetchMetadata(for url: URL) async throws -> LinkMetadata {
        // Check cache first
        if let cached = cache[url] {
            return cached
        }

        let provider = LPMetadataProvider()
        let metadata = try await provider.startFetchingMetadata(for: url)

        let linkMetadata = LinkMetadata(
            title: metadata.title,
            description: nil, // LPLinkMetadata doesn't expose description directly
            imageURL: metadata.imageProvider != nil ? url : nil
        )

        cache[url] = linkMetadata
        return linkMetadata
    }

    func extractURLs(from text: String) -> [URL] {
        text.extractedURLs
    }
}
