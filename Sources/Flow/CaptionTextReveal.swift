import Foundation

/// Display only. ASR revisions keep the amount already revealed; new suffixes
/// arrive in Unicode-safe steps instead of replacing the card with a paragraph.
public struct CaptionTextReveal: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var target = ""
    public var isComplete: Bool { text == target }
    public init() {}

    public mutating func retarget(_ target: String) {
        if !target.hasPrefix(text) { text = String(target.prefix(text.count)) }
        self.target = target
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard !isComplete else { return false }
        text = String(target.prefix(text.count + 1))
        return true
    }
}
