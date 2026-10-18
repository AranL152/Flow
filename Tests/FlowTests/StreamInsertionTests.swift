import XCTest
@testable import Flow

final class StreamInsertionTests: XCTestCase {
    func testStreamingOwnsOnlySelectedRangeAndUsesUTF16ForEmoji() throws {
        var buffer = try StreamInsertionBuffer(original: "before OLD after", selection: NSRange(location: 7, length: 3))
        let first = try buffer.propose(output: "hi ❤️", observedText: buffer.expectedText, observedSelection: buffer.expectedSelection)
        XCTAssertEqual(first.text, "before hi ❤️ after")
        buffer.acknowledge(first)
        let second = try buffer.propose(output: "hi ❤️ Alex\nsee you", observedText: buffer.expectedText, observedSelection: buffer.expectedSelection)
        XCTAssertEqual(second.text, "before hi ❤️ Alex\nsee you after")
        XCTAssertEqual(second.replacementRange.length, "hi ❤️".utf16.count)
        XCTAssertEqual(second.selection.location, 7 + "hi ❤️ Alex\nsee you".utf16.count)
    }

    func testUserEditsAndCursorMovesStopFutureWritesAndRollback() throws {
        var buffer = try StreamInsertionBuffer(original: "", selection: NSRange(location: 0, length: 0))
        buffer.acknowledge(try buffer.propose(output: "generated", observedText: "", observedSelection: NSRange(location: 0, length: 0)))
        XCTAssertThrowsError(try buffer.propose(output: "late tokens", observedText: "my edit", observedSelection: buffer.expectedSelection))
        XCTAssertThrowsError(try buffer.propose(output: "late tokens", observedText: buffer.expectedText, observedSelection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(buffer.canRestore(observedText: "my edit", observedSelection: buffer.expectedSelection))
        XCTAssertTrue(buffer.canRestore(observedText: buffer.expectedText, observedSelection: buffer.expectedSelection))
    }

    func testInvalidOrOversizedRangesAreRejected() throws {
        XCTAssertThrowsError(try StreamInsertionBuffer(original: "👋", selection: NSRange(location: 1, length: 0)))
        XCTAssertThrowsError(try StreamInsertionBuffer(original: "hi", selection: NSRange(location: 100, length: 1)))
        let buffer = try StreamInsertionBuffer(original: "", selection: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try buffer.propose(output: String(repeating: "x", count: 24001), observedText: "", observedSelection: NSRange(location: 0, length: 0)))
    }
}
