import XCTest
@testable import Flow

final class CaptionTextRevealTests: XCTestCase {
    func testLiveCaptionNeverQueuesAnOldParagraphAheadOfCurrentSpeech() {
        var reveal = CaptionTextReveal()
        let paragraph = String(repeating: "Earlier words fill the caption. ", count: 30)
        reveal.retarget(paragraph + "These are the newest words.", maximumAnimatedCharacters: 12)
        XCTAssertLessThanOrEqual(reveal.target.count - reveal.text.count, 12)
        var frames = 0
        while reveal.advance() { frames += 1 }
        XCTAssertLessThanOrEqual(frames, 4) // At most 132 ms, independent of paragraph length.
        XCTAssertTrue(reveal.text.hasSuffix("These are the newest words."))

        reveal.retarget("Corrected speech 👩🏽‍💻 ends here", maximumAnimatedCharacters: 12)
        XCTAssertLessThanOrEqual(reveal.target.count - reveal.text.count, 12)
        while reveal.advance() {}
        XCTAssertEqual(reveal.text, "Corrected speech 👩🏽‍💻 ends here")
    }

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
            XCTAssertGreaterThan(reveal.text.count, before)
            XCTAssertTrue(reveal.target.hasPrefix(reveal.text))
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
