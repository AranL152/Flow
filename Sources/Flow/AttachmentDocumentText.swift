import Foundation

/// Shared query handling for local document extraction and Spotlight content search.
enum AttachmentDocumentText {
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func terms(_ query: String) throws -> [String] {
        _ = try AttachmentFileSearch.terms(for: query)
        let filler: Set<String> = ["showing", "show", "shows", "with", "containing", "contains", "saying", "says", "reads", "reading", "mentioning", "mentions", "about", "that", "has", "the", "a", "an", "my", "of", "in", "on", "text", "pdf", "presentation", "slides", "slideshow", "deck", "powerpoint", "document"]
        var seen = Set<String>()
        let terms = words(query).filter { !filler.contains($0) && seen.insert($0).inserted }
        guard !terms.isEmpty else { throw AttachmentFailure.unavailable("Say words inside the document, for example ‘quarterly revenue’.") }
        return terms
    }

    static func supports(_ url: URL) -> Bool {
        ["pdf", "pptx", "ppt", "key"].contains(url.pathExtension.lowercased())
    }

    static func candidate(_ url: URL, terms: [String], location: String? = nil) throws -> AttachmentCandidate {
        try AttachmentCandidate(fileURL: url,
            sourceLabel: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            matchedDocumentText: terms, matchedLocation: location)
    }
}
