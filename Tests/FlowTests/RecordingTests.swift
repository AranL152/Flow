import XCTest
@testable import Flow

final class RecordingTests: XCTestCase {
    func testContactTitlesExcludeSetupWindowsAndPreserveGroupNames() {
        XCTAssertNil(MessagesContext.normalizedContact(" Messages "))
        XCTAssertNil(MessagesContext.normalizedContact("New Message"))
        XCTAssertNil(MessagesContext.normalizedContact("  "))
        XCTAssertEqual(MessagesContext.normalizedContact(" Alex "), "Alex")
        XCTAssertEqual(MessagesContext.normalizedContact("Alex, Sam + 2 more"), "Alex, Sam + 2 more")
    }
    func testSilenceAdvancesAndClearsSpeechPeaks() {
        var history = AudioWaveformHistory(barCount: 15)
        for _ in 0..<15 { history.tick(level: 0.2, recording: true) }
        XCTAssertGreaterThan(history.samples.last!, 0.5)
        // Constant zero must clear the graph even without an onChange event.
        for _ in 0..<60 { history.tick(level: 0, recording: true) }
        XCTAssertTrue(history.samples.allSatisfy { $0 == 0 })
    }

    func testLoudnessIsComparableAndBadSamplesStayFinite() {
        var quiet = AudioWaveformHistory(barCount: 1)
        var loud = AudioWaveformHistory(barCount: 1)
        for _ in 0..<20 {
            quiet.tick(level: 0.02, recording: true)
            loud.tick(level: 0.3, recording: true)
        }
        XCTAssertGreaterThan(loud.envelope, quiet.envelope)
        for level: Float in [.nan, .infinity, -.infinity, -2, 30] {
            loud.tick(level: level, recording: true)
            XCTAssertTrue(loud.envelope.isFinite)
            XCTAssertTrue((0...1).contains(loud.envelope))
        }
        for _ in 0..<60 { loud.tick(level: 1, recording: false) }
        XCTAssertEqual(loud.envelope, 0)
    }

    func testAudioReadWithoutRecordingDoesNotInventSamples() {
        let engine = Flow(dbPath: ":memory:")
        let chunk = engine.recordingSamples(after: 123)
        XCTAssertTrue(chunk.frames.isEmpty)
        XCTAssertEqual(chunk.nextOffset, 123)
        XCTAssertEqual(chunk.sampleRate, 0)
    }
}
