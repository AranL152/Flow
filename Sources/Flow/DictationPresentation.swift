import Foundation

/// Presentation pacing only: the provider keeps receiving at full speed. Only
/// genuine model deltas are revealed, and completion waits for their display.
public enum DictationPresentation {
    public static func smooth(_ source: AsyncThrowingStream<DictationStreamEvent, Error>) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        smooth(source, interval: .milliseconds(40))
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
                        if case .delta(let text) = event {
                            let pause: Duration
                            switch text.last {
                            case ".", "!", "?", "\n": pause = .milliseconds(160)
                            case ",", ";", ":": pause = .milliseconds(80)
                            default: pause = .zero
                            }
                            nextUpdate = clock.now.advanced(by: interval + pause)
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
        while events.isEmpty && !ended {
            await withCheckedContinuation { waiter = $0 }
        }
        if let error { throw error }
        guard let event = events.first else { return nil }
        if case .delta(let text) = event {
            // Reveal ordinary messages one grapheme at a time. Bound catch-up
            // to four graphemes so long provider bursts never become big jumps.
            let count = min(4, max(1, (text.count + 239) / 240))
            var end = text.index(text.startIndex, offsetBy: min(count, text.count))
            if let punctuation = text[..<end].firstIndex(where: { ".,!?;:\n".contains($0) }) {
                end = text.index(after: punctuation)
            }
            let frame = String(text[..<end])
            if end == text.endIndex { events.removeFirst() }
            else { events[0] = .delta(String(text[end...])) }
            return .delta(frame)
        }
        events.removeFirst()
        return event
    }
}
