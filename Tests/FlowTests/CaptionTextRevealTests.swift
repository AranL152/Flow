import XCTest
@testable import Flow

final class CaptionTextRevealTests: XCTestCase {
    func testLateFinalWordsAreRevealedBeforeCompletion() {
        var reveal = CaptionTextReveal()
        reveal.retarget("Here's the issue. Flow find")
        while reveal.advance() {}
        let partial = reveal.text
        reveal.retarget(partial + " the screenshot showing payment error.")
        XCTAssertEqual(reveal.text, partial)
        XCTAssertFalse(reveal.isComplete)
        while !reveal.isComplete {
            let before = reveal.text.count
            reveal.advance()
            XCTAssertEqual(reveal.text.count, before + 1)
        }
        XCTAssertEqual(reveal.text, "Here's the issue. Flow find the screenshot showing payment error.")
    }

    func testRecognitionRevisionsDoNotBlankTheCaptionOrSplitEmoji() {
        var reveal = CaptionTextReveal()
        reveal.retarget("The issue")
        while reveal.advance() {}
        reveal.retarget("Here's the issue 👩🏽‍💻")
        XCTAssertFalse(reveal.text.isEmpty)
        XCTAssertLessThan(reveal.text.count, reveal.target.count)
        while reveal.advance() {}
        XCTAssertEqual(reveal.text, "Here's the issue 👩🏽‍💻")
    }

}
