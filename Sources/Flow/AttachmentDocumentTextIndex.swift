import AppKit
import CryptoKit
import Foundation
import PDFKit
import Vision

/// On-demand, local PDF/PPTX reading. No document bytes or extracted text enter
/// the model prompt. Work and the private disposable cache are bounded.
public actor AttachmentDocumentTextIndex {
    public static let shared = AttachmentDocumentTextIndex()
    public struct Statistics: Sendable {
        public let extractions: Int
        public let cacheHits: Int
    }
    public struct SearchResult {
        public let matches: [AttachmentCandidate]
        /// Successful direct reads also prove when a stale Spotlight hit no longer matches.
        public let checkedURLs: Set<URL>
    }
    private struct Unit: Codable { let text: String; let location: String }
    private struct Entry: Codable {
        let fingerprint: String
        let units: [Unit]
        var accessed: Date
    }
    private let cacheFile: URL?
    private var entries: [String: Entry] = [:]
    private var extractions = 0
    private var cacheHits = 0

    public init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Flow/DocumentText", isDirectory: true)) {
        cacheFile = cacheDirectory?.appendingPathComponent("text-v1.json")
        if let cacheFile, let size = try? cacheFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 16 * 1024 * 1024, let data = try? Data(contentsOf: cacheFile),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = Self.bounded(loaded)
        }
    }

    public var statistics: Statistics { Statistics(extractions: extractions, cacheHits: cacheHits) }

    public func search(_ query: String, urls: [URL], budget: TimeInterval = 8) async throws -> [AttachmentCandidate] {
        try await searchResult(query, urls: urls, budget: budget).matches
    }

    public func searchResult(_ query: String, urls: [URL], budget: TimeInterval = 8) async throws -> SearchResult {
        let terms = try AttachmentDocumentText.terms(query)
        let deadline = Date().addingTimeInterval(max(0, min(budget, 15)))
        var matches: [AttachmentCandidate] = []
        var seen = Set<URL>()
        var checked = Set<URL>()
        defer { persist() }
        for url in urls.prefix(32) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            guard seen.insert(url.standardizedFileURL).inserted,
                  let initial = try? Self.document(url) else { continue }
            let key = Self.key(url.standardizedFileURL.path)
            let units: [Unit]
            if var entry = entries[key], entry.fingerprint == initial.fingerprint {
                entry.accessed = Date(); entries[key] = entry; cacheHits += 1; units = entry.units
            } else {
                do {
                    // A truncated/time-limited extraction is not persisted: the next
                    // query must be able to retry rather than cache a false negative.
                    units = try await extract(url, deadline: deadline)
                    try Task.checkCancellation()
                    guard try Self.document(url).fingerprint == initial.fingerprint else { continue }
                    extractions += 1
                    entries[key] = Entry(fingerprint: initial.fingerprint, units: units, accessed: Date())
                } catch is CancellationError { throw CancellationError() }
                catch { entries.removeValue(forKey: key); continue }
            }
            try Task.checkCancellation()
            guard let current = try? Self.document(url), current.fingerprint == initial.fingerprint else {
                entries.removeValue(forKey: key); continue
            }
            checked.insert(url.standardizedFileURL)
            let allWords = Set(AttachmentDocumentText.words(units.map(\.text).joined(separator: " ")))
            guard terms.allSatisfy(allWords.contains) else { continue }
            let location = units.first { unit in
                let words = Set(AttachmentDocumentText.words(unit.text))
                return terms.allSatisfy(words.contains)
            }?.location
            if let candidate = try? AttachmentDocumentText.candidate(url, terms: terms, location: location) { matches.append(candidate) }
        }
        try Task.checkCancellation()
        return SearchResult(matches: matches, checkedURLs: checked)
    }

    private static func document(_ url: URL) throws -> (candidate: AttachmentCandidate, fingerprint: String) {
        guard url.isFileURL, AttachmentFileSearch.eligiblePath(url), ["pdf", "pptx"].contains(url.pathExtension.lowercased()) else {
            throw AttachmentFailure.unavailable("Unsupported local document.")
        }
        var fresh = url; fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard let size = values.fileSize, (1...64 * 1024 * 1024).contains(size), let date = values.contentModificationDate,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else {
            throw AttachmentFailure.unavailable("Document is too large or is not downloaded.")
        }
        let candidate = try AttachmentCandidate(fileURL: url, sourceLabel: "Local document")
        return (candidate, "\(size):\(date.timeIntervalSince1970.bitPattern):\(String(describing: values.fileResourceIdentifier))")
    }

    private func extract(_ url: URL, deadline: Date) async throws -> [Unit] {
        switch url.pathExtension.lowercased() {
        case "pdf": return try await pdf(url, deadline: deadline)
        case "pptx": return try await presentation(url, deadline: deadline)
        default: return []
        }
    }

    private func pdf(_ url: URL, deadline: Date) async throws -> [Unit] {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount <= 200 else {
            throw AttachmentFailure.unavailable("PDF is locked, unreadable or exceeds 200 pages.")
        }
        var units: [Unit] = [], characters = 0, scans = 0
        for number in 0..<document.pageCount {
            try check(deadline)
            guard let page = document.page(at: number) else { continue }
            var text = page.string ?? ""
            if AttachmentDocumentText.words(text).isEmpty {
                guard scans < 12 else { continue }
                scans += 1
                // Render on the utility actor, at enough resolution for slide-sized
                // scans. The image is never written out or sent anywhere.
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { continue }
                let scale = min(2, 2400 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
                if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = try await Self.ocr(pixels)
                }
            }
            characters += text.count
            guard characters <= 128000 else { throw AttachmentFailure.unavailable("Document text exceeds the local search limit.") }
            units.append(Unit(text: text, location: "Page \(number + 1)"))
        }
        try check(deadline)
        return units
    }

    private func presentation(_ url: URL, deadline: Date) async throws -> [Unit] {
        let listing = try await AttachmentDocumentArchive.read(url, entry: nil, limit: 256000, deadline: deadline)
        guard let names = String(data: listing, encoding: .utf8) else { return [] }
        let allNames: [String] = names.split(separator: "\n").map { String($0) }
        let slideNames = allNames.filter {
            $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil
        }
        guard slideNames.count <= 200, Set(slideNames).count == slideNames.count else { throw AttachmentFailure.unavailable("Presentation exceeds the local search limit.") }
        var ordered = slideNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var verifiedOrder = false
        if allNames.contains("ppt/presentation.xml"), allNames.contains("ppt/_rels/presentation.xml.rels") {
            let presentation = try AttachmentSlideXML.parse(await AttachmentDocumentArchive.read(url, entry: "ppt/presentation.xml", limit: 1024 * 1024, deadline: deadline))
            let relationships = try AttachmentSlideXML.parse(await AttachmentDocumentArchive.read(url, entry: "ppt/_rels/presentation.xml.rels", limit: 1024 * 1024, deadline: deadline))
            let resolved = presentation.slideIDs.compactMap { relationships.relationships[$0] }.compactMap { Self.resolve($0, relativeTo: "ppt/presentation.xml") }
            if resolved.count == slideNames.count, Set(resolved) == Set(slideNames), Set(resolved).count == resolved.count {
                ordered = resolved; verifiedOrder = true
            }
        }
        var units: [Unit] = [], characters = 0, scans = 0
        for (number, name) in ordered.enumerated() {
            try check(deadline)
            let data = try await AttachmentDocumentArchive.read(url, entry: name, limit: 1024 * 1024, deadline: deadline)
            let slide = try AttachmentSlideXML.parse(data)
            var text = slide.text
            let relationshipName = "ppt/slides/_rels/" + (name as NSString).lastPathComponent + ".rels"
            if !slide.imageIDs.isEmpty, scans < 12, allNames.contains(relationshipName) {
                let relationships = try AttachmentSlideXML.parse(await AttachmentDocumentArchive.read(url, entry: relationshipName, limit: 1024 * 1024, deadline: deadline))
                for id in slide.imageIDs where scans < 12 {
                    try check(deadline)
                    guard let target = relationships.relationships[id], let path = Self.resolve(target, relativeTo: name),
                          path.range(of: #"^ppt/media/[A-Za-z0-9_. -]+$"#, options: .regularExpression) != nil, allNames.contains(path),
                          ["png", "jpg", "jpeg", "tif", "tiff", "bmp"].contains((path as NSString).pathExtension.lowercased()) else { continue }
                    scans += 1
                    let bytes = try await AttachmentDocumentArchive.read(url, entry: path, limit: 8 * 1024 * 1024, deadline: deadline)
                    if let image = Self.pixels(bytes) { text += "\n" + (try await Self.ocr(image)) }
                }
            }
            characters += text.count
            guard characters <= 128000 else { throw AttachmentFailure.unavailable("Presentation text exceeds the local search limit.") }
            units.append(Unit(text: text, location: verifiedOrder ? "Slide \(number + 1)" : "Slide text"))
        }
        try check(deadline)
        return units
    }

    private static func resolve(_ target: String, relativeTo entry: String) -> String? {
        guard !target.contains(":"), !target.contains("\\"), !target.hasPrefix("/"), !target.contains("%") else { return nil }
        let base = URL(fileURLWithPath: "/" + entry).deletingLastPathComponent()
        let value = String(base.appendingPathComponent(target).standardizedFileURL.path.dropFirst())
        guard value.hasPrefix("ppt/"), !value.contains(".."), value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func pixels(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    private func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw AttachmentFailure.unavailable("Document content search reached its time limit.") }
    }

    private static func ocr(_ image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        try await withTaskCancellationHandler {
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
        } onCancel: { request.cancel() }
        return (request.results ?? []).compactMap { observation -> String? in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return nil }
            return text.string
        }.joined(separator: "\n")
    }

    private static func key(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func bounded(_ entries: [String: Entry]) -> [String: Entry] {
        Dictionary(uniqueKeysWithValues: entries.filter { Date().timeIntervalSince($0.value.accessed) < 30 * 86400 }
            .sorted { $0.value.accessed > $1.value.accessed }.prefix(64).map { ($0.key, $0.value) })
    }
    private func persist() {
        entries = Self.bounded(entries)
        guard let cacheFile, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: cacheFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
        } catch { /* Search remains usable without a writable cache. */ }
    }
}

private final class AttachmentSlideXML: NSObject, XMLParserDelegate {
    private var capture = false
    private(set) var text = ""
    private(set) var imageIDs: [String] = []
    private(set) var slideIDs: [String] = []
    private(set) var relationships: [String: String] = [:]
    static func parse(_ data: Data) throws -> AttachmentSlideXML {
        // No DTD/entity expansion or external reads from untrusted documents.
        guard let xml = String(data: data, encoding: .utf8), !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw AttachmentFailure.unavailable("Unsupported slide XML.")
        }
        let delegate = AttachmentSlideXML(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw AttachmentFailure.unavailable("Unreadable slide text.") }
        return delegate
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        capture = elementName == "t" && ["http://schemas.openxmlformats.org/drawingml/2006/main", "http://purl.oclc.org/ooxml/drawingml/main"].contains(namespaceURI ?? "")
        if elementName == "blip", let id = attributes["r:embed"] { imageIDs.append(id) }
        if elementName == "sldId", let id = attributes["r:id"] { slideIDs.append(id) }
        if elementName == "Relationship", attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"],
           let type = attributes["Type"], type.hasSuffix("/slide") || type.hasSuffix("/image") { relationships[id] = target }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if capture { text += " " }; capture = false
    }
}
