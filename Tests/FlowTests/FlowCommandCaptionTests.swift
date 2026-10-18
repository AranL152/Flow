import XCTest
@testable import Flow

final class FlowCommandCaptionTests: XCTestCase {
    func testExplicitCommandsPreserveTheExactSpokenBoundary() {
        for (text, message, command) in [
            ("Here's the issue. Flow, find the screenshot showing payment error.", "Here's the issue. ", "Flow, find the screenshot showing payment error."),
            ("Hi 👩🏽‍💻 Alex! Hey Flow. Attach my clipboard", "Hi 👩🏽‍💻 Alex! ", "Hey Flow. Attach my clipboard"),
            ("FLOW SEARCH FOR my files", "", "FLOW SEARCH FOR my files")
        ] {
            let result = FlowCommandCaption.detect(in: text)
            XCTAssertEqual(result?.message, message)
            XCTAssertEqual(result?.command, command)
            XCTAssertEqual(result.map { $0.message + $0.command }, text)
        }
    }

    func testMentionsQuotedReportedAndNegatedSpeechStayOrdinaryText() {
        for text in [
            "I use Flow every day", "Let's go with the flow", "workflow find my file", "Flow", "Flowing water",
            "Flow, attach", "Flow find", "Flow search for…", "Flow, attach!!!",
            "The tutorial says \"Flow, find my screenshot\"", "“Flow, attach my clipboard”",
            "‘Flow find my screenshot’", "'Flow find my screenshot'", "I told Flow attach my clipboard",
            "Don't Flow find my file", "Don’t Flow attach my clipboard", "Do not Flow find my screenshot",
            "Never Flow attach my clipboard", "The phrase Flow attach my clipboard", "Write Flow find my screenshot"
        ] { XCTAssertNil(FlowCommandCaption.detect(in: text), text) }
    }

    func testCompleteCommandWaitsForRecordingToStopBeforeHighlighting() {
        let text = "Here's the deck. Flow, attach the PDF I just downloaded."
        for partial in ["Here's the deck.", "Here's the deck. Flow", "Here's the deck. Flow, attach", text] {
            XCTAssertNil(FlowCommandCaption.detect(in: partial, isRecording: true), partial)
        }
        let completed = FlowCommandCaption.detect(in: text, isRecording: false)
        XCTAssertEqual(completed?.message, "Here's the deck. ")
        XCTAssertEqual(completed?.command, "Flow, attach the PDF I just downloaded.")
        XCTAssertNil(FlowCommandCaption.detect(in: "Let's go with the flow.", isRecording: false))
        XCTAssertNil(FlowCommandCaption.detect(in: "She said ‘Flow, attach my clipboard’.", isRecording: false))
    }

    func testCompletedQuotesAndNewSentenceDoNotBlockAnActualInstruction() {
        XCTAssertNotNil(FlowCommandCaption.detect(in: "She said ‘thanks’. Flow find the deck"))
        XCTAssertNotNil(FlowCommandCaption.detect(in: "I said yes. Flow attach the image on my clipboard"))
        XCTAssertNotNil(FlowCommandCaption.detect(in: "Here's the deck. Flow attach my clipboard"))
    }

    func testHighlightNeverParsesAVisibleTailWithoutItsOriginalContext() {
        let longReported = "The tutorial says \"" + String(repeating: "example ", count: 80) + "Flow find the screenshot\""
        XCTAssertNil(FlowCommandCaption.detect(in: longReported))
        let longMessage = String(repeating: "context ", count: 80) + ". Flow find the screenshot"
        XCTAssertEqual(FlowCommandCaption.detect(in: longMessage)?.command, "Flow find the screenshot")
        XCTAssertNil(FlowCommandCaption.detect(in: String(repeating: "x", count: 20001) + " Flow find my file"))
    }
}
