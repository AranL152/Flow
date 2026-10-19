import XCTest
@testable import Flow

final class LiveRewritePresentationTests: XCTestCase {
    func testNewestRecognitionWordWaitsForMoreContext() {
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Can you review"))
        XCTAssertEqual(LiveRewritePresentation.candidate(from: "Can you review the slides"), "Can you review the")
    }

    func testPendingAndRecognizedCommandsAreWithheldFromLiveRewrite() {
        for suffix in ["Flow", "Flow, attach", "Flow, find", "Flow search for", "Flow, find the screenshot", "Flow add", "Flow include the image", "Flow look", "Flow look for", "Flow grab the screenshot", "Flow please", "Flow could you", "Flow could you please add"] {
            XCTAssertEqual(LiveRewritePresentation.candidate(from: "Here is the dashboard. " + suffix), "Here is the dashboard.")
        }
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Flow, attach the screenshot"))
    }

    func testOrdinaryMentionsAreRetainedAndOversizeSpeechWaitsForFinalPath() {
        XCTAssertEqual(LiveRewritePresentation.candidate(from: "I use Flow every day"), "I use Flow every")
        XCTAssertNil(LiveRewritePresentation.candidate(from: String(repeating: "word ", count: 1100)))
    }

    func testReplacementDoesNotRestartTheVisiblePhraseFromItsFirstWord() {
        XCTAssertFalse(LiveRewritePresentation.canDisplay("got", replacing: "got a sec?"))
        XCTAssertTrue(LiveRewritePresentation.canDisplay("got a sec to review?", replacing: "got a sec?"))
        XCTAssertTrue(LiveRewritePresentation.canDisplay("thanks", replacing: "got a sec?", completed: true))
    }
}
