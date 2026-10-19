import Foundation

/// ASR corrections update already visible text once. Only the new suffix animates.
public struct CaptionTextReveal: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var target = ""
    public var isComplete: Bool { text == target }
    public init() {}

    public mutating func retarget(_ target: String) {
        if !target.hasPrefix(text) {
            text = String(target.prefix(text.count))
        }
        self.target = target
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard !isComplete else { return false }
        let remaining = String(target.dropFirst(text.count))
        text += remaining.prefix(TextRevealPacing.charactersPerFrame(backlog: remaining.count))
        return true
    }
}
