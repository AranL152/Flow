import Foundation

/// Presentation pacing only: the provider keeps receiving at full speed. Only
/// genuine model deltas are revealed, and completion waits for their display.
public enum DictationPresentation {
    public static func smooth(_ source: AsyncThrowingStream<DictationStreamEvent, Error>) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        smooth(source, interval: TextRevealPacing.frameInterval)
    }

    static func smooth(_ source: AsyncThrowingStream<DictationStreamEvent, Error>, interval: Duration) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let buffer = PresentationBuffer()
            let receiving = Task {
                do {
                    for try await event in source {
                        try Task.checkCancellation()
                        await buffer.append(event)
                    }
                    await buffer.finish()
                } catch { await buffer.finish(error: error) }
            }
            let presenting = Task {
                defer { receiving.cancel() }
                let clock = ContinuousClock()
                var nextUpdate: ContinuousClock.Instant?
                do {
                    while true {
                        if let nextUpdate { try await clock.sleep(until: nextUpdate) }
                        try Task.checkCancellation()
                        guard let event = try await buffer.next() else { break }
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) { break }
                        if case .delta = event {
                            nextUpdate = clock.now.advanced(by: interval)
                        } else { nextUpdate = nil }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in
                receiving.cancel(); presenting.cancel()
                Task { await buffer.finish(error: CancellationError()) }
            }
        }
    }
}

private actor PresentationBuffer {
    private var events: [DictationStreamEvent] = []
    private var ended = false
    private var error: Error?
    private var waiter: CheckedContinuation<Void, Never>?

    func append(_ event: DictationStreamEvent) {
        guard !ended else { return }
        if case .delta(let text) = event {
            guard !text.isEmpty else { return }
            if let last = events.last, case .delta(let previous) = last {
                events[events.count - 1] = .delta(previous + text)
            } else { events.append(event) }
        } else { events.append(event) }
        waiter?.resume(); waiter = nil
    }

    func finish(error: Error? = nil) {
        guard !ended || error != nil else { return }
        ended = true
        if let error { self.error = error; events.removeAll() }
        waiter?.resume(); waiter = nil
    }

    func next() async throws -> DictationStreamEvent? {
        while true {
            if let error { throw error }
            if let event = events.first {
                if case .delta(let text) = event {
                    // A later provider fragment can extend the last grapheme
                    // (an accent, skin tone or emoji joiner). Keep that one
                    // pending while the stream is open, not the whole word.
                    let available = text.count - (ended || events.count > 1 ? 0 : 1)
                    if available > 0 {
                        let amount = TextRevealPacing.charactersPerFrame(backlog: available)
                        let end = text.index(text.startIndex, offsetBy: amount)
                        let frame = String(text[..<end])
                        if end == text.endIndex { events.removeFirst() }
                        else { events[0] = .delta(String(text[end...])) }
                        return .delta(frame)
                    }
                } else {
                    events.removeFirst()
                    return event
                }
            } else if ended { return nil }
            await withCheckedContinuation { waiter = $0 }
        }
    }
}

/// Whitespace travels with the following word, preserving the exact provider
/// spelling, punctuation, newlines and Unicode without exposing partial tokens.
func nextWordEnd(in text: String, final: Bool) -> String.Index? {
    var sawWord = false
    for index in text.indices {
        if text[index].isWhitespace {
            if sawWord { return index }
        } else { sawWord = true }
    }
    return final ? text.endIndex : nil
}
