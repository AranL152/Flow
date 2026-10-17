import XCTest
@testable import Flow

final class DemoStreamTests: XCTestCase {
    func testLiveTokensThenMatchingCompletion() throws {
        var decoder = DemoStreamDecoder()
        _ = try decoder.accept(line: "event: delta")
        _ = try decoder.accept(line: "data: {\"text\":\"hello ❤️\"}")
        XCTAssertEqual(try decoder.accept(line: ""), .delta("hello ❤️"))
        XCTAssertFalse(decoder.completed)
        XCTAssertThrowsError(try decoder.finish())
        _ = try decoder.accept(line: "event: done")
        _ = try decoder.accept(line: "data: {\"text\":\"hello ❤️\"}")
        XCTAssertEqual(try decoder.accept(line: ""), .done("hello ❤️"))
        XCTAssertNoThrow(try decoder.finish())
    }
    func testErrorsAndMismatchedCompletionAreNotSendable() throws {
        for event in ["event: error\ndata: {\"error\":\"lost connection\"}", "event: done\ndata: {\"text\":\"invented\"}"] {
            var decoder = DemoStreamDecoder()
            for line in event.split(separator: "\n") { _ = try decoder.accept(line: String(line)) }
            XCTAssertThrowsError(try decoder.accept(line: ""))
            XCTAssertFalse(decoder.completed)
        }
    }
    func testRustFFISendReceiptAndRecipientIsolation() throws {
        let engine = Flow(dbPath: ":memory:")
        func call(_ request: [String: Any]) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: engine.demoRequest(request)) as! [String: Any]
        }
        let prepared = try call(["op":"prepare", "recipient_id":"alex", "said":"please review this", "context":"Project review"])
        let ticket = prepared["ticket"] as! String
        XCTAssertThrowsError(try call(["op":"send", "ticket":ticket, "text":"yo can u check this"]))
        _ = try call(["op":"complete", "ticket":ticket, "output":"Dear Alex, please review this."])
        let receipt = try call(["op":"send", "ticket":ticket, "text":"yo can u check this"])
        XCTAssertEqual(receipt["edited"] as? Bool, true)
        XCTAssertThrowsError(try call(["op":"send", "ticket":ticket, "text":"duplicate"]))
        let next = try call(["op":"prepare", "recipient_id":"alex", "said":"review slides", "context":"Project review"])
        XCTAssertEqual((next["evidence_ids"] as? [String])?.count, 1)
        let mum = try call(["op":"prepare", "recipient_id":"mum", "said":"review slides", "context":"Project review"])
        XCTAssertEqual((mum["evidence_ids"] as? [String])?.count, 0)
    }
}
