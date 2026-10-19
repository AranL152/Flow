import Foundation

/// Display only. ASR revisions keep the amount already revealed; new suffixes
/// arrive in whole-word steps instead of replacing the card with a paragraph.
public struct CaptionTextReveal: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var target = ""
    public var isComplete: Bool { text == target }
    public init() {}

    public mutating func retarget(_ target: String) {
        if !target.hasPrefix(text) {
            let shownWords = text.split(whereSeparator: \.isWhitespace).count
            var end = target.startIndex
            for _ in 0..<shownWords {
                let remaining = String(target[end...])
                guard !remaining.isEmpty, let boundary = nextWordEnd(in: remaining, final: true) else { break }
                end = target.index(end, offsetBy: remaining.distance(from: remaining.startIndex, to: boundary))
            }
            text = String(target[..<end])
        }
        self.target = target
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard !isComplete else { return false }
        let remaining = String(target.dropFirst(text.count))
        guard let end = nextWordEnd(in: remaining, final: true) else { return false }
        text += remaining[..<end]
        return true
    }
}
