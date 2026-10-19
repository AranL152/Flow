import XCTest
@testable import Flow

final class LiveRewriteDeadlineTests: XCTestCase {
    func testStallCancelsUpstreamAndAllowsTheLatestPhraseToRun() async throws {
        let cancelled = expectation(description: "Underlying stalled request cancelled")
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("partial"))
            c.onTermination = { _ in cancelled.fulfill() }
        }
        let began = ContinuousClock.now
        do {
            for try await event in LiveRewritePresentation.bounded(source, idle: .milliseconds(120), total: .seconds(5)) {
                if case .completed = event { XCTFail("Stalled text became complete") }
            }
            XCTFail("Expected idle deadline")
        } catch LiveRewriteStreamError.stalled {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertLessThan(began.duration(to: .now), .seconds(1))
        await fulfillment(of: [cancelled], timeout: 1)

        let fresh = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            c.yield(.delta("latest phrase")); c.yield(.completed("latest phrase")); c.finish()
        }
        var final = ""
        for try await event in LiveRewritePresentation.bounded(fresh) {
            if case .completed(let text) = event { final = text }
        }
        XCTAssertEqual(final, "latest phrase")
    }

    func testActiveButOverlongPreviewHasABoundedTotalBudget() async throws {
        let source = AsyncThrowingStream<DictationStreamEvent, Error> { c in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        c.yield(.delta("next "))
                        try await Task.sleep(for: .milliseconds(30))
                    }
                } catch {}
            }
            c.onTermination = { _ in task.cancel() }
        }
        var count = 0
        do {
            for try await event in LiveRewritePresentation.bounded(source, idle: .seconds(1), total: .milliseconds(250)) {
                if case .delta = event { count += 1 }
                if case .completed = event { XCTFail("Incomplete preview became complete") }
            }
            XCTFail("Expected total deadline")
        } catch LiveRewriteStreamError.deadline {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertGreaterThan(count, 3)
    }
}
