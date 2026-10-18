import CryptoKit
import Foundation
import ImageIO
import Vision

/// On-demand OCR of recent screenshots. Nothing in this index is uploaded or
/// included in an LLM prompt. Its disk cache is private, bounded and disposable.
public actor AttachmentImageTextIndex {
    public static let shared = AttachmentImageTextIndex()
    public struct Statistics: Sendable {
        public let recognitions: Int
        public let cacheHits: Int
    }
    private struct Entry: Codable {
        let fingerprint: String
        let text: String
        var accessed: Date
    }
    private var entries: [String: Entry] = [:]
    private let cacheFile: URL?
    private let recognize: @Sendable (URL) async throws -> String
    private var recognitions = 0
    private var cacheHits = 0

    public init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Flow/ScreenshotOCR", isDirectory: true)) {
        self.init(cacheDirectory: cacheDirectory, recognize: { url in try await Self.recognizeText(url) })
    }

    init(cacheDirectory: URL?, recognize: @escaping @Sendable (URL) async throws -> String) {
        self.cacheFile = cacheDirectory?.appendingPathComponent("text-v1.json")
        self.recognize = recognize
        if let cacheFile,
           let size = try? cacheFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
           let data = try? Data(contentsOf: cacheFile),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = Self.bounded(loaded.filter { Date().timeIntervalSince($0.value.accessed) < 30 * 86400 })
        }
    }

    public var statistics: Statistics { Statistics(recognitions: recognitions, cacheHits: cacheHits) }

    /// The caller supplies recent Spotlight results; recheck all metadata before
    /// opening pixels, including for a cache hit or a file removed since indexing.
    public func search(_ query: String, urls: [URL], now: Date = Date()) async throws -> [AttachmentCandidate] {
        let terms = try Self.searchWords(query)
        var matches: [AttachmentCandidate] = []
        var seen = Set<URL>()
        defer { persist() }
        for url in urls.prefix(24) {
            try Task.checkCancellation()
            guard seen.insert(url.standardizedFileURL).inserted,
                  let initial = try? Self.screenshot(url, now: now) else { continue }
            let key = Self.key(url.standardizedFileURL.path)
            let text: String
            if var entry = entries[key], entry.fingerprint == initial.fingerprint {
                cacheHits += 1; entry.accessed = now; entries[key] = entry; text = entry.text
            } else {
                do {
                    text = String(try await recognize(url).prefix(16000))
                    try Task.checkCancellation()
                    try initial.candidate.validate()
                    recognitions += 1
                    entries[key] = Entry(fingerprint: initial.fingerprint, text: text, accessed: now)
                } catch is CancellationError { throw CancellationError() }
                catch { entries.removeValue(forKey: key); continue }
            }
            do { try initial.candidate.validate() }
            catch { entries.removeValue(forKey: key); continue }
            let words = Set(Self.words(text))
            guard terms.allSatisfy({ words.contains($0) }) else { continue }
            if let candidate = try? AttachmentCandidate(fileURL: url, sourceLabel: initial.candidate.sourceLabel, matchedImageText: terms) {
                matches.append(candidate)
            }
        }
        try Task.checkCancellation()
        return matches
    }

    static func searchWords(_ query: String) throws -> [String] {
        _ = try AttachmentFileSearch.terms(for: query)
        let filler: Set<String> = ["showing", "show", "shows", "with", "containing", "contains", "saying", "says", "reads", "reading", "that", "has", "the", "a", "an", "my", "of", "in", "on", "screenshot", "image", "photo", "picture", "text"]
        var seen = Set<String>()
        let terms = words(query).filter { !filler.contains($0) && seen.insert($0).inserted }
        guard !terms.isEmpty else { throw AttachmentFailure.unavailable("Say words visible in the screenshot, for example ‘payment error’.") }
        return terms
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func screenshot(_ url: URL, now: Date) throws -> (candidate: AttachmentCandidate, fingerprint: String) {
        guard url.isFileURL, AttachmentFileSearch.eligiblePath(url), AttachmentDownloads.matches(url, kind: .image) else {
            throw AttachmentFailure.unavailable("Not a readable screenshot.")
        }
        var fresh = url; fresh.removeAllCachedResourceValues()
        let value = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                                                       .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard let size = value.fileSize, (1...24 * 1024 * 1024).contains(size), let date = value.contentModificationDate,
              date >= now.addingTimeInterval(-30 * 86400), date <= now.addingTimeInterval(300),
              value.isUbiquitousItem != true || value.ubiquitousItemDownloadingStatus == .current || value.ubiquitousItemDownloadingStatus == .downloaded else {
            throw AttachmentFailure.unavailable("Screenshot is too old, large or not downloaded.")
        }
        let candidate = try AttachmentCandidate(fileURL: url, sourceLabel: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        return (candidate, "\(size):\(date.timeIntervalSince1970.bitPattern):\(String(describing: value.fileResourceIdentifier))")
    }

    private static func key(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func bounded(_ values: [String: Entry]) -> [String: Entry] {
        Dictionary(uniqueKeysWithValues: values.sorted { $0.value.accessed > $1.value.accessed }.prefix(128).map { ($0.key, $0.value) })
    }

    private func persist() {
        entries = Self.bounded(entries.filter { Date().timeIntervalSince($0.value.accessed) < 30 * 86400 })
        guard let cacheFile, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: cacheFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
        } catch { /* A cache failure must not prevent choosing a file. */ }
    }

    private static func recognizeText(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3072,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AttachmentFailure.unavailable("Couldn't read screenshot pixels.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try await withTaskCancellationHandler {
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
        } onCancel: { request.cancel() }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return nil }
            return text.string
        }.joined(separator: "\n")
    }
}
