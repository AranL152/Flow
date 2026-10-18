import XCTest
@testable import Flow

final class DictationStreamingTests: XCTestCase {
    func testReceiverPreservesTokenOrderAndCancellation() async throws {
        var receiver: DictationStreamReceiver!
        let stream = AsyncThrowingStream<DictationStreamEvent, Error> { continuation in
            receiver = DictationStreamReceiver(continuation: continuation)
        }
        XCTAssertTrue(receiver.accept("")) // liveness check, never a token
        XCTAssertTrue(receiver.accept("hi ❤️"))
        XCTAssertTrue(receiver.accept(" Alex"))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual(first, .delta("hi ❤️"))
        XCTAssertEqual(second, .delta(" Alex"))
        receiver.cancel()
        XCTAssertFalse(receiver.accept(" late token"))
    }

    func testMissingAudioIsAnErrorInsteadOfACompletedDraft() async {
        let engine = Flow(dbPath: ":memory:")
        do {
            for try await event in engine.transcribeStream(appName: "Messages") {
                XCTFail("Missing audio emitted \(event)")
            }
            XCTFail("Missing audio succeeded")
        } catch { XCTAssertTrue(error.localizedDescription.contains("audio")) }
    }
}
