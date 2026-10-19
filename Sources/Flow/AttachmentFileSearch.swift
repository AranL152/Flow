import Foundation

/// Filename search in the local Spotlight index. File contents never leave the Mac.
/// Screenshot text recognition is handled separately by AttachmentImageTextIndex.
@MainActor
public final class AttachmentFileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<[URL], Error>?
    private var searchID: UUID?

    public init() {}

    public nonisolated static func terms(for text: String) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 12, trimmed.count <= 160,
              trimmed.rangeOfCharacter(from: .alphanumerics) != nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw AttachmentFailure.unavailable("Enter words from a filename or document, for example ‘robotics’ or ‘quarterly revenue’.")
        }
        return words
    }

    public func search(_ text: String, kind: AttachmentRequest.Kind, scopes: [URL]? = nil) async throws -> [AttachmentCandidate] {
        let terms = try Self.terms(for: text)
        let metadata = NSMetadataQuery()
        let predicates = terms.map {
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*")
        }
        // Spotlight rejects an AND node with only one child (an ObjC exception).
        metadata.predicate = predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return Self.candidates(from: try await gather(metadata, scopes: scopes), text: text, kind: kind)
    }

    /// Read only a bounded set of recent screenshot URLs from Spotlight. Generic
    /// screenshot names cover captures whose screen-capture metadata was lost.
    public func recentScreenshots(scopes: [URL]? = nil, now: Date = Date(), limit: Int = 24) async throws -> [URL] {
        let metadata = NSMetadataQuery()
        let screenshot = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture"),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "Screenshot*"),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "Screen Shot*")
        ])
        metadata.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [screenshot,
            NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, now.addingTimeInterval(-30 * 86400) as NSDate)])
        let urls = try await gather(metadata, scopes: scopes)
        return Array(urls.filter { Self.eligiblePath($0) && AttachmentDownloads.matches($0, kind: .image) }.prefix(max(0, min(limit, 24))))
    }

    /// Spotlight searches importer-provided text without exposing the full text.
    /// Keynote and legacy PowerPoint rely on the installed Spotlight importer.
    public func documentContents(_ text: String, kind: AttachmentRequest.Kind, scopes: [URL]? = nil) async throws -> [AttachmentCandidate] {
        let terms = try AttachmentDocumentText.terms(text)
        let metadata = NSMetadataQuery()
        let predicates = terms.map { NSPredicate(format: "%K ==[cd] %@", "kMDItemTextContent", $0) }
        metadata.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [Self.documentTypes(kind)] + predicates)
        return try await gather(metadata, scopes: scopes).compactMap { url in
            guard Self.eligiblePath(url), AttachmentDocumentText.supports(url), AttachmentDownloads.matches(url, kind: kind) else { return nil }
            return try? AttachmentDocumentText.candidate(url, terms: terms)
        }
    }

    /// Bounded fallback for PDFs/PPTX whose content Spotlight hasn't indexed yet.
    /// There is no age cutoff: older indexed content can still match above.
    public func recentDocuments(kind: AttachmentRequest.Kind, scopes: [URL]? = nil) async throws -> [URL] {
        let metadata = NSMetadataQuery()
        metadata.predicate = Self.documentTypes(kind)
        return Array(try await gather(metadata, scopes: scopes).filter {
            Self.eligiblePath($0) && ["pdf", "pptx"].contains($0.pathExtension.lowercased()) && AttachmentDownloads.matches($0, kind: kind)
        }.prefix(32))
    }

    private static func documentTypes(_ kind: AttachmentRequest.Kind) -> NSPredicate {
        let extensions = kind == .pdf ? ["pdf"] : kind == .presentation ? ["pptx", "ppt", "key"] : ["pdf", "pptx", "ppt", "key"]
        let predicates = extensions.map {
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*.\($0)")
        }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }

    private func gather(_ metadata: NSMetadataQuery, scopes: [URL]?) async throws -> [URL] {
        cancel()
        try Task.checkCancellation()
        let id = UUID()
        searchID = id
        metadata.searchScopes = (scopes ?? [FileManager.default.homeDirectoryForCurrentUser]).map { $0 as Any }
        metadata.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query = metadata
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadata, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.searchID == id, let metadata = self.query else { return }
                        metadata.disableUpdates()
                        let urls = (0..<min(metadata.resultCount, 1000)).compactMap {
                            index -> URL? in
                            guard let item = metadata.result(at: index) as? NSMetadataItem else { return nil }
                            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL { return url }
                            return (item.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
                        }
                        self.complete(.success(urls))
                    }
                }
                guard metadata.start() else {
                    complete(.failure(AttachmentFailure.unavailable("Spotlight search couldn't start. Choose a file manually.")))
                    return
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled, let self, self.searchID == id else { return }
                    self.complete(.failure(AttachmentFailure.unavailable("Spotlight search timed out. Try fewer filename words, or choose a file manually.")))
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.searchID == id { self?.cancel() }
            }
        }
    }

    /// Also validates Spotlight results, which may be stale or point to hidden,
    /// incomplete, unreadable or replaced files. Never recursively scans folders.
    public nonisolated static func candidates(from urls: [URL], text: String, kind: AttachmentRequest.Kind) -> [AttachmentCandidate] {
        guard let terms = try? terms(for: text) else { return [] }
        var seen = Set<URL>()
        var results: [AttachmentCandidate] = []
        // Spotlight supplies recency order. Preserve it when names score equally.
        let ranked = urls.enumerated().sorted {
            let a = filenameScore($0.element, terms: terms), b = filenameScore($1.element, terms: terms)
            return a == b ? $0.offset < $1.offset : a > b
        }
        for (_, url) in ranked {
            guard url.isFileURL, seen.insert(url.standardizedFileURL).inserted,
                  eligiblePath(url),
                  !["crdownload", "download", "part", "partial", "tmp"].contains(url.pathExtension.lowercased()),
                  terms.allSatisfy({ url.lastPathComponent.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }),
                  AttachmentDownloads.matches(url, kind: kind) else { continue }
            if let candidate = try? AttachmentCandidate(fileURL: url, sourceLabel: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                results.append(candidate)
                if results.count == 12 { break }
            }
        }
        return results
    }

    nonisolated static func eligiblePath(_ url: URL) -> Bool {
        !url.pathComponents.contains { $0.hasPrefix(".") || ["Library", "node_modules"].contains($0) || $0.hasSuffix(".app") }
    }

    nonisolated static func filenameScore(_ url: URL, terms: [String]) -> Int {
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let name = words(url.deletingPathExtension().lastPathComponent)
        let query = terms.flatMap(words)
        if name == query { return 1000 }
        let phrase = query.joined(separator: " ")
        return (name.joined(separator: " ").contains(phrase) ? 300 : 100) - max(0, name.count - query.count)
    }

    public func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ result: Result<[URL], Error>) {
        timeout?.cancel(); timeout = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query?.stop(); query = nil; searchID = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
