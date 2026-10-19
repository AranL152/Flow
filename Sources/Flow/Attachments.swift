import AppKit
import Foundation
import UniformTypeIdentifiers

public struct AttachmentPlan: Codable, Equatable, Sendable {
    public let message: String
    public let command: String
    public let request: AttachmentRequest?
    public let clarification: String?
}

public struct AttachmentRequest: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case clipboard, recentDownload = "recent_download", fileSearch = "file_search" }
    public enum Kind: String, Codable, Sendable { case any, image, pdf, presentation }
    public let source: Source
    public let kind: Kind
    public let query: String?

    public init(source: Source, kind: Kind, query: String? = nil) { self.source = source; self.kind = kind; self.query = query }
}

public enum AttachmentFailure: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// A preview owns image bytes; files are revalidated before use. No arbitrary
/// model paths ever enter this type or the native source providers.
public struct AttachmentCandidate: Identifiable {
    public let id = UUID()
    public let filename: String
    public let sourceLabel: String
    public let fileURL: URL?
    public let imageData: Data?
    public let approximateRecency: Bool
    /// Query words found by local OCR; never the image's complete extracted text.
    public let matchedImageText: [String]
    /// Only the requested words and their location, never a full document excerpt.
    public let matchedDocumentText: [String]
    public let matchedLocation: String?
    public var matchDescription: String? {
        let words = matchedDocumentText.isEmpty ? matchedImageText : matchedDocumentText
        return words.isEmpty ? nil : "Matches: \"" + words.joined(separator: " ") + "\"" + (matchedLocation.map { " · \($0)" } ?? "")
    }
    private let fileSize: Int?
    private let modified: Date?
    private let identity: NSObject?

    init(imageData: Data) {
        filename = "Clipboard image"; sourceLabel = "Image from clipboard"
        fileURL = nil; self.imageData = imageData; approximateRecency = false
        fileSize = nil; modified = nil; identity = nil; matchedImageText = []; matchedDocumentText = []; matchedLocation = nil
    }

    public init(fileURL: URL, sourceLabel: String, approximateRecency: Bool = false, matchedImageText: [String] = [], matchedDocumentText: [String] = [], matchedLocation: String? = nil) throws {
        var freshURL = fileURL
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw AttachmentFailure.unavailable("That file is unavailable or is a link. Choose the original file.")
        }
        self.fileURL = fileURL; imageData = nil; filename = fileURL.lastPathComponent
        self.sourceLabel = sourceLabel; self.approximateRecency = approximateRecency; self.matchedImageText = matchedImageText
        self.matchedDocumentText = matchedDocumentText; self.matchedLocation = matchedLocation
        fileSize = values.fileSize; modified = values.contentModificationDate
        identity = values.fileResourceIdentifier as? NSObject
    }

    public func validate() throws {
        guard let fileURL else {
            guard let imageData, !imageData.isEmpty else { throw AttachmentFailure.unavailable("The clipboard image is no longer available.") }
            return
        }
        let current = try AttachmentCandidate(fileURL: fileURL, sourceLabel: sourceLabel)
        guard current.fileSize == fileSize, current.modified == modified,
              identity == nil || identity?.isEqual(current.identity) == true else {
            throw AttachmentFailure.unavailable("The file changed after the preview. Refresh before attaching it.")
        }
    }

    /// Writes only when explicitly requested by the caller; never sends.
    public func write(to board: NSPasteboard) throws {
        try validate()
        if let fileURL {
            board.clearContents()
            guard board.writeObjects([fileURL as NSURL]) else { throw AttachmentFailure.unavailable("Couldn't copy the file.") }
        } else if let imageData, let image = NSImage(data: imageData) {
            board.clearContents()
            guard board.writeObjects([image]) else { throw AttachmentFailure.unavailable("Couldn't copy the image.") }
        } else { throw AttachmentFailure.unavailable("Couldn't read the image.") }
    }
}

/// Read at recording start, before Flow can replace the general clipboard.
public struct AttachmentClipboardSnapshot {
    public let changeCount: Int
    private let urls: [URL]
    private let image: Data?

    public init(board: NSPasteboard = .general) {
        changeCount = board.changeCount
        urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let bytes = board.data(forType: .png) ?? board.data(forType: .tiff)
        image = bytes.flatMap { $0.count <= 64 * 1024 * 1024 ? $0 : nil }
    }

    public func resolve(kind: AttachmentRequest.Kind) throws -> AttachmentCandidate {
        if !urls.isEmpty {
            guard urls.count == 1 else { throw AttachmentFailure.unavailable("Multiple files were copied. Copy one file and refresh.") }
            guard AttachmentDownloads.matches(urls[0], kind: kind) else {
                throw AttachmentFailure.unavailable("The copied file doesn't match the requested type.")
            }
            return try AttachmentCandidate(fileURL: urls[0], sourceLabel: "File from clipboard")
        }
        guard kind == .any || kind == .image, let image, NSImage(data: image) != nil else {
            throw AttachmentFailure.unavailable("No matching image or file was on the clipboard when recording started. Copy it, then refresh.")
        }
        return AttachmentCandidate(imageData: image)
    }
}

/// Observes completed files while Flow is running. At cold start, filesystem
/// directory-arrival metadata is an approximation, exposed as a choice in UI.
public final class AttachmentDownloads {
    private struct Observation { let arrival: Date; let size: Int?; let modified: Date?; let firstStableAt: Date; let observedArrival: Bool }
    public let directory: URL
    private var observations: [URL: Observation] = [:]
    private let fileManager: FileManager
    private var hasObserved = false

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        self.fileManager = fileManager
    }

    public static func matches(_ url: URL, kind: AttachmentRequest.Kind) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return kind == .any }
        switch kind {
        case .any: return true
        case .image: return type.conforms(to: .image)
        case .pdf: return type.conforms(to: .pdf)
        case .presentation: return type.conforms(to: .presentation) || ["ppt", "pptx", "key"].contains(url.pathExtension.lowercased())
        }
    }

    private func eligible(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return !name.hasPrefix(".") && !["crdownload", "download", "part", "partial", "tmp"].contains(url.pathExtension.lowercased())
    }

    /// A repeated observation is required: an active download must not be picked
    /// just because its final extension is already present.
    public func observe(now: Date = Date()) throws {
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey], options: [.skipsHiddenFiles])
        var next: [URL: Observation] = [:]
        for url in files where eligible(url) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { continue }
            let previous = observations[url]
            let unchanged = previous != nil && previous?.size == values.fileSize && previous?.modified == values.contentModificationDate
            let observedArrival = previous?.observedArrival ?? hasObserved
            let arrival = previous?.arrival ?? (hasObserved ? now : values.addedToDirectoryDate ?? .distantPast)
            next[url] = Observation(arrival: arrival, size: values.fileSize, modified: values.contentModificationDate,
                firstStableAt: unchanged ? previous!.firstStableAt : now, observedArrival: observedArrival)
        }
        observations = next
        hasObserved = true
    }

    public func candidates(kind: AttachmentRequest.Kind, now: Date = Date()) throws -> [AttachmentCandidate] {
        try observe(now: now)
        let ordered = observations.filter { Self.matches($0.key, kind: kind) }
            .sorted { a, b in a.value.arrival == b.value.arrival ? a.key.path < b.key.path : a.value.arrival > b.value.arrival }
        guard let newest = ordered.first else { throw AttachmentFailure.unavailable("No completed matching file was found in Downloads.") }
        guard now.timeIntervalSince(newest.value.firstStableAt) >= 1 else {
            throw AttachmentFailure.unavailable("The newest matching file may still be downloading. Wait a moment, then refresh.")
        }
        let uncertain = !newest.value.observedArrival || ordered.dropFirst().first.map { abs($0.value.arrival.timeIntervalSince(newest.value.arrival)) < 1 } == true
        return try ordered.prefix(uncertain ? 5 : 1).map { url, observation in
            try AttachmentCandidate(fileURL: url, sourceLabel: "Downloads", approximateRecency: uncertain)
        }
    }
}
