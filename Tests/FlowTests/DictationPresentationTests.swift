import XCTest
@testable import Flow

final class DictationPresentationTests: XCTestCase {
    func testBurstsRevealInSmallUnicodeSafeFramesBeforeCompletion() async throws {
        let text = "Hi 👩🏽‍💻 Alex! Cafe\u{301} ❤️ let's meet."
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta(text)); c.yield(.completed(text)); c.finish()
        }
        var frames: [String] = []
        var completed = false
        for try await event in DictationPresentation.smooth(source, interval: .zero) {
            switch event {
            case .delta(let frame):
                XCTAssertFalse(completed)
                XCTAssertLessThanOrEqual(frame.count, 2)
                frames.append(frame)
            case .completed(let final):
                completed = true
                XCTAssertEqual(frames.joined(), final)
            default: XCTFail("Unexpected event")
            }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(frames.joined(), text)
        XCTAssertTrue(frames.joined().contains("👩🏽‍💻"))
    }

    func testMetadataOrderAndTokenBoundariesDoNotChangeText() async throws {
        let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"Hi Alex","command":"Flow, attach clipboard","request":{"source":"clipboard","kind":"image"}}"#.utf8))
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.attachment(plan))
            for t in ["H", "i", "", " ", "Al", "ex"] { c.yield(.delta(t)) }
            c.yield(.completed("Hi Alex")); c.finish()
        }
        var events: [DictationStreamEvent] = []
        for try await event in DictationPresentation.smooth(source, interval: .zero) { events.append(event) }
        XCTAssertEqual(events.first, .attachment(plan))
        XCTAssertEqual(events.last, .completed("Hi Alex"))
        XCTAssertEqual(events.compactMap { if case .delta(let t) = $0 { return t }; return nil }.joined(), "Hi Alex")
    }

    func testCancellationStopsBufferedTextAndNeverCompletes() async throws {
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta(String(repeating: "abc", count: 200)))
            c.yield(.completed("should not appear")); c.finish()
        }
        let task = Task { () -> Bool in
            do {
                for try await event in DictationPresentation.smooth(source) {
                    if case .completed = event { return false }
                    try Task.checkCancellation()
                }
                return Task.isCancelled
            } catch { return error is CancellationError || Task.isCancelled }
        }
        try await Task.sleep(for: .milliseconds(70))
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }


    func testFastProviderBurstStillHasSteadyPresentationTime() async throws {
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("abcdefgh")); c.yield(.completed("abcdefgh")); c.finish()
        }
        var times: [ContinuousClock.Instant] = []
        let clock = ContinuousClock()
        for try await event in DictationPresentation.smooth(source) {
            if case .delta = event { times.append(clock.now) }
        }
        XCTAssertEqual(times.count, 4)
        for (before, after) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(before.duration(to: after), .milliseconds(40))
        }
    }

    func testUpstreamFailureDoesNotBecomeCompletion() async {
        struct Failure: Error {}
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("partial")); c.finish(throwing: Failure())
        }
        do {
            for try await event in DictationPresentation.smooth(source) {
                if case .completed = event { XCTFail("Failure became a completed draft") }
            }
            XCTFail("Error was swallowed")
        } catch { XCTAssertTrue(error is Failure) }
    }
}
