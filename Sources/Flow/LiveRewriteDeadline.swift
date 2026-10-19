import Foundation

public enum LiveRewriteStreamError: LocalizedError {
    case stalled, deadline
    public var errorDescription: String? {
        switch self {
        case .stalled: return "Live rewrite stopped responding; retrying the latest speech."
        case .deadline: return "Live rewrite exceeded its preview budget; refreshing the latest speech."
        }
    }
}

extension LiveRewritePresentation {
    /// A speculative request must not hold newer speech hostage to a long HTTP
    /// timeout. Cancellation reaches the native receiver and Rust's heartbeat.
    public static func bounded(_ source: AsyncThrowingStream<DictationStreamEvent, Error>,
                               idle: Duration = .seconds(2), total: Duration = .seconds(6)) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let progress = PreviewProgress()
            let receiving = Task {
                do {
                    for try await event in source {
                        try Task.checkCancellation()
                        guard await progress.observe(event) else { return }
                        continuation.yield(event)
                    }
                    if await progress.finish() { continuation.finish() }
                } catch {
                    if await progress.finish() { continuation.finish(throwing: error) }
                }
            }
            let watching = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    if let failure = await progress.expiration(idle: idle, total: total) {
                        receiving.cancel()
                        continuation.finish(throwing: failure)
                        return
                    }
                    if await progress.hasEnded { return }
                }
            }
            continuation.onTermination = { @Sendable _ in receiving.cancel(); watching.cancel() }
        }
    }
}

private actor PreviewProgress {
    private let began = ContinuousClock.now
    private var lastText = ContinuousClock.now
    private(set) var hasEnded = false

    func observe(_ event: DictationStreamEvent) -> Bool {
        guard !hasEnded else { return false }
        if case .delta(let text) = event, !text.isEmpty { lastText = .now }
        return true
    }

    func finish() -> Bool {
        guard !hasEnded else { return false }
        hasEnded = true
        return true
    }

    func expiration(idle: Duration, total: Duration) -> LiveRewriteStreamError? {
        guard !hasEnded else { return nil }
        let now = ContinuousClock.now
        let failure: LiveRewriteStreamError?
        if began.duration(to: now) >= total { failure = .deadline }
        else if lastText.duration(to: now) >= idle { failure = .stalled }
        else { failure = nil }
        if failure != nil { hasEnded = true }
        return failure
    }
}
