import Foundation

public enum DictationStreamEvent: Equatable, Sendable {
    case delta(String)
    case attachment(AttachmentPlan)
    case completed(String)
}

final class DictationStreamReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let continuation: AsyncThrowingStream<DictationStreamEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<DictationStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func accept(_ text: String) -> Bool {
        guard !isCancelled else { return false }
        if !text.isEmpty {
            if case .terminated = continuation.yield(.delta(text)) { cancel(); return false }
        }
        return !isCancelled
    }
}

func nativeDictationDelta(_ delta: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Bool {
    guard let context, let delta else { return false }
    return Unmanaged<DictationStreamReceiver>.fromOpaque(context).takeUnretainedValue().accept(String(cString: delta))
}
