import XCTest
@testable import Flow

final class LiveRewritePresentationTests: XCTestCase {
    func testNewestRecognitionWordWaitsForMoreContext() {
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Can you review"))
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Can you review the slides"))
        XCTAssertEqual(LiveRewritePresentation.candidate(from: "Can you review the slides. And maybe"), "Can you review the slides.")
    }

    func testPendingAndRecognizedCommandsAreWithheldFromLiveRewrite() {
        for suffix in ["Flow", "Flow, attach", "Flow, find", "Flow search for", "Flow, find the screenshot", "Flow add", "Flow include the image", "Flow look", "Flow look for", "Flow grab the screenshot", "Flow please", "Flow could you", "Flow could you please add"] {
            XCTAssertEqual(LiveRewritePresentation.candidate(from: "Here is the dashboard. " + suffix), "Here is the dashboard.")
        }
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Flow, attach the screenshot"))
    }

    func testOrdinaryMentionsAreRetainedAndOversizeSpeechWaitsForFinalPath() {
        XCTAssertNil(LiveRewritePresentation.candidate(from: "I use Flow every day"))
        XCTAssertNil(LiveRewritePresentation.candidate(from: String(repeating: "word ", count: 1100)))
    }

    func testOnlyNewCompletedSentencesAreSubmitted() {
        XCTAssertEqual(LiveRewritePresentation.nextSentence(from: "Here is the report. Let me know.", after: "Here is the report."), "Let me know.")
        XCTAssertNil(LiveRewritePresentation.nextSentence(from: "Here is the report. Let me", after: "Here is the report."))
        XCTAssertNil(LiveRewritePresentation.nextSentence(from: "Here are the reports. Let me know.", after: "Here is the report."))
        XCTAssertNil(LiveRewritePresentation.candidate(from: "Please ask Dr. Smith to review"))
        XCTAssertNil(LiveRewritePresentation.candidate(from: "The cost is 3.25 dollars"))
    }

    func testReplacementDoesNotRestartTheVisiblePhraseFromItsFirstWord() {
        XCTAssertFalse(LiveRewritePresentation.canDisplay("got", replacing: "got a sec?"))
        XCTAssertTrue(LiveRewritePresentation.canDisplay("got a sec to review?", replacing: "got a sec?"))
        XCTAssertTrue(LiveRewritePresentation.canDisplay("thanks", replacing: "got a sec?", completed: true))
    }
}
