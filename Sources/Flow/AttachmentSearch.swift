import Foundation

/// Combines deterministic filenames with locally recognized screenshot words.
/// Only an explicit image search opens screenshots; other file searches stay fast.
@MainActor
public final class AttachmentSearch {
    private let filenames = AttachmentFileSearch()
    private let screenshots = AttachmentFileSearch()
    private let index: AttachmentImageTextIndex
    private let scopes: [URL]?

    public init(scopes: [URL]? = nil, index: AttachmentImageTextIndex = .shared) {
        self.scopes = scopes; self.index = index
    }

    public func search(_ text: String, kind: AttachmentRequest.Kind) async throws -> [AttachmentCandidate] {
        let terms = try AttachmentFileSearch.terms(for: text)
        var filenameMatches: [AttachmentCandidate] = []
        var filenameError: Error?
        do { filenameMatches = try await filenames.search(text, kind: kind, scopes: scopes) }
        catch is CancellationError { throw CancellationError() }
        catch { filenameError = error }
        guard kind == .image else {
            if let filenameError { throw filenameError }
            return filenameMatches
        }
        try Task.checkCancellation()
        do {
            let urls = try await screenshots.recentScreenshots(scopes: scopes)
            let recognized = try await index.search(text, urls: urls)
            try Task.checkCancellation()
            var byURL = Dictionary(uniqueKeysWithValues: filenameMatches.compactMap { candidate in candidate.fileURL.map { ($0.standardizedFileURL, candidate) } })
            for candidate in recognized { if let url = candidate.fileURL { byURL[url.standardizedFileURL] = candidate } }
            let filenameURLs = Set(filenameMatches.compactMap { $0.fileURL?.standardizedFileURL })
            // Preserve the provider's recency order on equal scores.
            let order = (recognized + filenameMatches).compactMap { $0.fileURL?.standardizedFileURL }
            var seen = Set<URL>()
            let ordered = order.filter { seen.insert($0).inserted }.compactMap { byURL[$0] }
            func score(_ candidate: AttachmentCandidate) -> Int {
                guard let url = candidate.fileURL else { return 0 }
                let name = AttachmentFileSearch.filenameScore(url, terms: terms)
                if filenameURLs.contains(url.standardizedFileURL), name >= 1000 { return 2000 }
                if !candidate.matchedImageText.isEmpty { return 1000 }
                return name
            }
            let ranked = ordered.enumerated().sorted {
                let a = score($0.element), b = score($1.element)
                return a == b ? $0.offset < $1.offset : a > b
            }.prefix(12).map(\.element)
            if ranked.isEmpty, let filenameError { throw filenameError }
            return ranked
        } catch is CancellationError { throw CancellationError() }
        catch {
            // OCR/Spotlight availability must not break a valid filename result.
            if !filenameMatches.isEmpty { return filenameMatches }
            throw error
        }
    }

    public func cancel() { filenames.cancel(); screenshots.cancel() }
}
