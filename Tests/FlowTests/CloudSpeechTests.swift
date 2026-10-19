import XCTest
@testable import Flow

final class CloudSpeechTests: XCTestCase {
    private func result(_ text: String, final: Bool, start: Double = 0, duration: Double = 1, confidence: Double = 0.99) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "Results", "start": start, "duration": duration,
            "is_final": final, "channel": ["alternatives": [["transcript": text, "confidence": confidence]]]])
    }
    private let metadata = Data("{\"type\":\"Metadata\"}".utf8)

    func testInterimRevisionsNeverBecomeCompletedDictation() throws {
        var speech = CloudSpeechTranscript()
        try speech.receive(result("Here's the", final: false), closing: false)
        try speech.receive(result("Here's the issue.", final: false), closing: false)
        XCTAssertEqual(speech.text, "Here's the issue.")
        try speech.receive(metadata, closing: true)
        XCTAssertNil(speech.finalText, "An unfinalized revision must use recorded-audio fallback")
    }

    func testPausesAccumulateSegmentsAndCloseFlushesTheLastWordsOnce() throws {
        var speech = CloudSpeechTranscript()
        try speech.receive(metadata, closing: false)
        XCTAssertFalse(speech.closed)
        try speech.receive(result("Here's the issue.", final: true), closing: false)
        try speech.receive(result("Here's the issue.", final: true), closing: false)
        try speech.receive(result("Flow find the screen", final: false, start: 1), closing: false)
        try speech.receive(result("Flow find the screenshot.", final: true, start: 1), closing: true)
        XCTAssertNil(speech.finalText, "A pause is not the end of a recording")
        try speech.receive(metadata, closing: true)
        XCTAssertEqual(speech.finalText, "Here's the issue. Flow find the screenshot.")
    }

    func testEmptySpeechAndBrokenStreamsCannotBecomeCompletedDictation() throws {
        var speech = CloudSpeechTranscript()
        try speech.receive(result("", final: true), closing: true)
        try speech.receive(metadata, closing: true)
        XCTAssertNil(speech.finalText)
        for data in [Data("garbage".utf8), Data("{\"type\":\"Error\"}".utf8), Data(repeating: 0, count: 131073)] {
            XCTAssertThrowsError(try speech.receive(data, closing: true))
        }
    }

    func testQuotaAndTransientFailuresKeepTheirActionableReason() throws {
        for code in ["quota_exhausted", "rate_limited", "timeout", "unavailable"] {
            var speech = CloudSpeechTranscript()
            let data = try JSONSerialization.data(withJSONObject: ["type": "Error", "code": code])
            XCTAssertThrowsError(try speech.receive(data, closing: false)) { error in
                XCTAssertEqual((error as? CloudSpeechServiceFailure)?.code, code)
                if code == "quota_exhausted" { XCTAssertTrue(error.localizedDescription.contains("Workers Paid")) }
            }
            XCTAssertNil(speech.finalText)
        }
    }

    func testFinalBackupRejectsPartialUncertainAndInvalidRecognition() {
        XCTAssertEqual(SpeechFinalTranscript.accepted("  Call me Ishmael. ", final: true, confidence: 0.95), "Call me Ishmael.")
        XCTAssertNil(SpeechFinalTranscript.accepted("Call me", final: false, confidence: 0.99))
        XCTAssertNil(SpeechFinalTranscript.accepted("uncertain", final: true, confidence: 0.7))
        XCTAssertNil(SpeechFinalTranscript.accepted("empty", final: true, confidence: .nan))
        XCTAssertNil(SpeechFinalTranscript.accepted(" ", final: true, confidence: 0.99))
        XCTAssertNil(SpeechFinalTranscript.accepted(String(repeating: "x", count: 5001), final: true, confidence: 0.99))
    }

    @MainActor
    func testCaptionBurstDeliversNewestRevisionAndCancellationDropsOldSpeech() async throws {
        let delivery = SpeechCaptionDelivery()
        var displayed: [String] = []
        delivery.onText = { displayed.append($0) }
        delivery.submit("Here is the opening page. Flow add")
        delivery.submit("Here is the opening page.")
        delivery.submit("Here is the opening page. Flow add the screenshot")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(displayed, ["Here is the opening page. Flow add the screenshot"])
        delivery.submit("Old recording")
        delivery.cancel()
        delivery.submit("New recording")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(displayed.last, "New recording")
        XCTAssertFalse(displayed.contains("Old recording"))
    }

    func testUnicodeAndOutputLimit() throws {
        var speech = CloudSpeechTranscript()
        try speech.receive(result("Hey Alex 👋 — café?", final: true), closing: true)
        try speech.receive(metadata, closing: true)
        XCTAssertEqual(speech.finalText, "Hey Alex 👋 — café?")
        XCTAssertThrowsError(try speech.receive(result(String(repeating: "x", count: 5001), final: false, start: 2), closing: false))
    }

    func testUncertainFinalSpeechUsesAudioFallback() throws {
        var speech = CloudSpeechTranscript()
        try speech.receive(result("uncertain wording", final: true, confidence: 0.7), closing: true)
        try speech.receive(metadata, closing: true)
        XCTAssertNil(speech.finalText)
        XCTAssertEqual(speech.minimumConfidence, 0.7)
    }

    @MainActor
    func testNoAudioOrCancellationReturnsFallbackWithoutConnecting() async {
        let speech = CloudSpeechStream(endpoint: URL(string: "ws://127.0.0.1:1"))
        speech.start()
        let empty = await speech.finish()
        XCTAssertNil(empty)
        speech.cancel()
        let cancelled = await speech.finish()
        XCTAssertNil(cancelled)
        XCTAssertEqual(speech.sentFrames, 0)
    }

    @MainActor
    func testStalledStreamDoesNotAddAFinalizationWait() async {
        let speech = CloudSpeechStream(endpoint: URL(string: "ws://127.0.0.1:1"))
        speech.start()
        speech.append(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
        let start = ContinuousClock.now
        let result = await speech.finish()
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
        XCTAssertNotNil(speech.failureDescription)
    }
}
