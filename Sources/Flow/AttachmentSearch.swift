import Foundation

/// Combines filenames, screenshot OCR and local PDF/presentation content.
/// Content reads happen only for an explicit file-search command.
@MainActor
public final class AttachmentSearch {
    private let filenames = AttachmentFileSearch()
    private let screenshots = AttachmentFileSearch()
    private let index: AttachmentImageTextIndex
    private let documents = AttachmentFileSearch()
    private let documentIndex: AttachmentDocumentTextIndex
    private let scopes: [URL]?

    public init(scopes: [URL]? = nil, index: AttachmentImageTextIndex = .shared, documentIndex: AttachmentDocumentTextIndex = .shared) {
        self.scopes = scopes; self.index = index; self.documentIndex = documentIndex
    }

    public func search(_ text: String, kind: AttachmentRequest.Kind) async throws -> [AttachmentCandidate] {
        let terms = try AttachmentFileSearch.terms(for: text)
        var filenameMatches: [AttachmentCandidate] = []
        var filenameError: Error?
        do { filenameMatches = try await filenames.search(text, kind: kind, scopes: scopes) }
        catch is CancellationError { throw CancellationError() }
        catch { filenameError = error }
        try Task.checkCancellation()
        do {
            let recognized: [AttachmentCandidate]
            if kind == .image {
                let urls = try await screenshots.recentScreenshots(scopes: scopes)
                recognized = try await index.search(text, urls: urls)
            } else {
                var indexed: [AttachmentCandidate] = []
                do { indexed = try await documents.documentContents(text, kind: kind, scopes: scopes) }
                catch is CancellationError { throw CancellationError() }
                catch { /* A missing importer must not prevent direct reading. */ }
                var local: [AttachmentCandidate] = []
                var checked = Set<URL>()
                do {
                    let recent = try await documents.recentDocuments(kind: kind, scopes: scopes)
                    let pool = indexed.compactMap(\.fileURL) + recent
                    let urls = pool.reduce(into: [URL]()) { result, url in
                        if !result.contains(url) { result.append(url) }
                    }
                    let result = try await documentIndex.searchResult(text, urls: urls, budget: indexed.isEmpty ? 8 : 2)
                    local = result.matches; checked = result.checkedURLs
                } catch is CancellationError { throw CancellationError() }
                catch { /* Preserve validated Spotlight or filename matches. */ }
                recognized = local + indexed.filter { $0.fileURL.map { !checked.contains($0.standardizedFileURL) } ?? false }
            }
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
                if !candidate.matchedImageText.isEmpty || !candidate.matchedDocumentText.isEmpty { return 1000 }
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

    public func cancel() { filenames.cancel(); screenshots.cancel(); documents.cancel() }
}
