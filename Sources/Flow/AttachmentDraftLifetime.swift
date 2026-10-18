/// Popup lifetime only, never a send/learning signal. Two readable empty
/// observations after a nonempty draft dismiss stale attachment suggestions.
public struct AttachmentDraftLifetime: Sendable {
    private var sawContent = false
    private var emptyObservations = 0
    public init() {}

    public mutating func observe(hasContent: Bool?) -> Bool {
        guard let hasContent else { emptyObservations = 0; return false }
        if hasContent { sawContent = true; emptyObservations = 0; return false }
        guard sawContent else { return false }
        emptyObservations += 1
        return emptyObservations >= 2
    }
}
