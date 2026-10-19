import Foundation

public enum PresentedDictationEvent: Sendable, Equatable {
    case text(String)
    case attachment(AttachmentPlan)
    case completed(String)
}

extension DictationPresentation {
    /// Consume repeated model prefixes at network speed. Existing text is never
    /// typed out again; only available new characters are paced for display.
    public static func reconcile(_ source: AsyncThrowingStream<DictationStreamEvent, Error>,
                                 replacing visibleText: String = "",
                                 onReceive: (@Sendable (DictationStreamEvent) -> Void)? = nil) -> AsyncThrowingStream<PresentedDictationEvent, Error> {
        AsyncThrowingStream { continuation in
            let buffer = SnapshotBuffer(visibleText)
            let receiving = Task {
                do {
                    for try await event in source {
                        try Task.checkCancellation()
                        onReceive?(event)
                        await buffer.append(event)
                    }
                    await buffer.finish()
                } catch { await buffer.finish(error: error) }
            }
            let presenting = Task {
                defer { receiving.cancel() }
                do {
                    while let event = try await buffer.next() {
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) { break }
                        if case .text = event { try await Task.sleep(for: TextRevealPacing.frameInterval) }
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

private actor SnapshotBuffer {
    private enum Item { case target(String, final: Bool), event(PresentedDictationEvent) }
    private var items: [Item] = []
    private var modelText = ""
    private var reveal = CaptionTextReveal()
    private var ended = false
    private var error: Error?
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ visibleText: String) {
        reveal.retarget(visibleText)
        while reveal.advance() {}
    }

    func append(_ event: DictationStreamEvent) {
        guard !ended else { return }
        switch event {
        case .delta(let text):
            guard !text.isEmpty else { return }
            modelText += text
            // Hold one extendable grapheme, including accents and emoji joiners.
            target(String(modelText.dropLast()), final: false)
        case .attachment(let plan): items.append(.event(.attachment(plan)))
        case .completed(let text):
            target(text, final: true)
            items.append(.event(.completed(text)))
        }
        waiter?.resume(); waiter = nil
    }

    private func target(_ text: String, final: Bool) {
        if let last = items.last, case .target = last { items[items.count - 1] = .target(text, final: final) }
        else { items.append(.target(text, final: final)) }
    }

    func finish(error: Error? = nil) {
        guard !ended || error != nil else { return }
        ended = true
        if let error { self.error = error; items.removeAll() }
        waiter?.resume(); waiter = nil
    }

    func next() async throws -> PresentedDictationEvent? {
        while true {
            if let error { throw error }
            if let item = items.first {
                switch item {
                case .event(let event): items.removeFirst(); return event
                case .target(let text, let final):
                    // A new full-prefix generation must catch up before it can
                    // replace existing text. This wait consumes no display time.
                    if !final && text.count < reveal.text.count { items.removeFirst(); continue }
                    let previous = reveal.text
                    reveal.retarget(text)
                    reveal.advance()
                    if reveal.isComplete { items.removeFirst() }
                    if reveal.text != previous { return .text(reveal.text) }
                }
            } else if ended { return nil }
            else { await withCheckedContinuation { waiter = $0 } }
        }
    }
}
