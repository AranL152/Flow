import XCTest
@testable import Flow

final class DictationSnapshotsTests: XCTestCase {
    func testAlreadyVisibleLongPrefixDoesNotReplayBeforeNewSuffix() async throws {
        let baseline = String(repeating: "Already visible. ", count: 120)
        let final = baseline + "Thanks Alex!"
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            for character in final { c.yield(.delta(String(character))) }
            c.yield(.completed(final)); c.finish()
        }
        let began = ContinuousClock.now
        var frames: [String] = []
        for try await event in DictationPresentation.reconcile(source, replacing: baseline) {
            switch event {
            case .text(let text):
                XCTAssertTrue(text.hasPrefix(baseline))
                frames.append(text)
            case .completed(let text): XCTAssertEqual(frames.last, text)
            default: XCTFail("Unexpected event")
            }
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(1))
        XCTAssertEqual(frames.last, final)
        XCTAssertLessThanOrEqual(frames.count, "Thanks Alex!".count)
    }

    func testShorterValidatedRewriteCorrectsTheDraftWithoutBlankingIt() async throws {
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("Thanks!")); c.yield(.completed("Thanks!")); c.finish()
        }
        var frames: [String] = []
        for try await event in DictationPresentation.reconcile(source, replacing: "Thanks so much for reviewing everything!") {
            if case .text(let text) = event { frames.append(text) }
            if case .completed = event { XCTAssertEqual(frames.last, "Thanks!") }
        }
        XCTAssertEqual(frames, ["Thanks!"])
    }

    func testGraphemesSplitAcrossProviderFragmentsNeverAppearBroken() async throws {
        let final = "Hi 👩🏽‍💻 Cafe\u{301}!"
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            Task {
                for part in ["Hi ", "👩", "🏽", "\u{200D}", "💻", " Caf", "e", "\u{301}", "!"] {
                    c.yield(.delta(part))
                    try await Task.sleep(for: .milliseconds(45))
                }
                c.yield(.completed(final)); c.finish()
            }
        }
        var last = ""
        for try await event in DictationPresentation.reconcile(source) {
            if case .text(let text) = event {
                XCTAssertEqual(Array(text), Array(final.prefix(text.count)))
                last = text
            }
        }
        XCTAssertEqual(last, final)
    }

    func testLargeFastResponseDrainsInSecondsWithoutLosingMetadataOrText() async throws {
        let final = String(repeating: "A long passage. ", count: 90)
        let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"","command":"Flow attach clipboard","request":{"source":"clipboard","kind":"image"}}"#.utf8))
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta(final)); c.yield(.attachment(plan)); c.yield(.completed(final)); c.finish()
        }
        let began = ContinuousClock.now
        var last = "", sawAttachment = false, completed = false
        for try await event in DictationPresentation.reconcile(source) {
            switch event {
            case .text(let text): XCTAssertFalse(completed); last = text
            case .attachment(let found): XCTAssertEqual(found, plan); sawAttachment = true
            case .completed(let text):
                XCTAssertTrue(sawAttachment); XCTAssertEqual(last, text); completed = true
            }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(last, final)
        XCTAssertLessThan(began.duration(to: .now), .seconds(4))
    }

    func testFailureAndCancellationCannotPromotePartialText() async throws {
        struct Failure: Error {}
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("partial")); c.finish(throwing: Failure())
        }
        do {
            for try await event in DictationPresentation.reconcile(source) {
                if case .completed = event { XCTFail("Unvalidated partial became complete") }
            }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is Failure) }
    }
}
