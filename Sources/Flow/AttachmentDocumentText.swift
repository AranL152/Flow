import Foundation

/// Shared query handling for local document extraction and Spotlight content search.
enum AttachmentDocumentText {
    static func words(_ text: String) -> [String] {
        var normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Speech recognizers spell the same quarter as Q2, Q two, or second quarter.
        for (number, ordinal, cardinal) in [(1, "first", "one"), (2, "second", "two"), (3, "third", "three"), (4, "fourth", "four")] {
            for pattern in [#"\bq[\s-]*(?:"# + String(number) + "|" + cardinal + #")\b"#,
                            #"\b"# + ordinal + #"\s+quarter\b"#,
                            #"\bquarter\s+(?:"# + String(number) + "|" + cardinal + #")\b"#] {
                normalized = normalized.replacingOccurrences(of: pattern, with: "q\(number)", options: .regularExpression)
            }
        }
        return normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func terms(_ query: String) throws -> [String] {
        _ = try AttachmentFileSearch.terms(for: query)
        let filler: Set<String> = ["showing", "show", "shows", "with", "containing", "contains", "saying", "says", "reads", "reading", "mentioning", "mentions", "about", "that", "has", "the", "a", "an", "my", "of", "in", "on", "from", "for", "text", "pdf", "presentation", "slides", "slideshow", "deck", "powerpoint", "document"]
        var seen = Set<String>()
        let terms = words(query).filter { !filler.contains($0) && seen.insert($0).inserted }
        guard !terms.isEmpty else { throw AttachmentFailure.unavailable("Say words inside the document, for example ‘quarterly revenue’.") }
        return terms
    }

    /// Keep the document topic strict, but show other periods as alternatives.
    /// A query containing only a quarter/year still requires that exact period.
    static func requiredTerms(_ terms: [String]) -> [String] {
        let topic = terms.filter { $0.range(of: #"^(?:q[1-4]|(?:19|20|21)\d{2})$"#, options: .regularExpression) == nil }
        return topic.isEmpty ? terms : topic
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
