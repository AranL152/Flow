import Foundation

/// Shared query handling for local document extraction and Spotlight content search.
enum AttachmentDocumentText {
    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                                "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let spokenYears: [NSRegularExpression] = {
        let ones = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        let teens = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let suffix = "(?:\(tens)(?:[ -]+\(ones))?|\(teens)|oh[ -]+\(ones))"
        return [#"\btwo[ -]+thousand(?:[ -]+and)?(?:[ -]+("# + suffix + "|" + ones + #"))?\b"#,
                #"\btwenty[ -]+("# + suffix + #")\b"#].map { try! NSRegularExpression(pattern: $0) }
    }()

    private static func normalizeSpokenYears(_ value: String) -> String {
        var value = value
        for pattern in spokenYears {
            for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                let suffix = Range(match.range(at: 1), in: value).map { String(value[$0]) } ?? ""
                let parts = suffix.split { $0 == " " || $0 == "-" }.map(String.init)
                let number = parts.reduce(0) { $0 + (tens[$1] ?? units.firstIndex(of: $1) ?? 0) }
                value.replaceSubrange(range, with: String(2000 + number))
            }
        }
        return value
    }

    static func words(_ text: String) -> [String] {
        var normalized = normalizeSpokenYears(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
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
