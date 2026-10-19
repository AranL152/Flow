import Foundation

/// ASR corrections update already visible text once. Only the new suffix animates.
public struct CaptionTextReveal: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var target = ""
    private var followsSpeech = false
    public var isComplete: Bool { text == target }
    public init() {}

    public mutating func retarget(_ target: String, maximumAnimatedCharacters: Int? = nil) {
        followsSpeech = maximumAnimatedCharacters != nil
        if !target.hasPrefix(text) {
            text = String(target.prefix(text.count))
        }
        self.target = target
        // Captions must follow current speech even when ASR delivers a burst.
        // Keep only a short trailing reveal; model output uses the default pace.
        if let maximumAnimatedCharacters {
            let minimumVisible = max(0, target.count - max(0, maximumAnimatedCharacters))
            if text.count < minimumVisible { text = String(target.prefix(minimumVisible)) }
        }
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard !isComplete else { return false }
        let remaining = String(target.dropFirst(text.count))
        let amount = TextRevealPacing.charactersPerFrame(backlog: remaining.count)
        text += remaining.prefix(followsSpeech ? max(3, amount) : amount)
        return true
    }
}
