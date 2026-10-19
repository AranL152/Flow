import XCTest
@testable import Flow

final class RecordingTests: XCTestCase {
    func testSavedContactChipUsesNameWhileValidatingItsCommittedEmail() {
        typealias Node = MessagesContext.HeaderNode
        let chip = Node(role: "AXPopUpButton", description: "Morgan, morgan@example.invalid, Not registered")
        for value in ["\u{FFFC}", "To:\u{FFFC}Morgan", "To:\u{FFFC}morgan@example.invalid", "To:\u{FFFC}Morgan, morgan@example.invalid"] {
            let to = Node(role: "AXTextField", identifier: "To:", description: "To:", value: value)
            XCTAssertEqual(MessagesContext.contactFromHeader(Node(children: [to, chip])), "Morgan", "Committed serialization: \(value)")
        }
        let uncommitted = Node(role: "AXTextField", identifier: "To:", value: "\u{FFFC}Morgan another@example.invalid")
        XCTAssertNil(MessagesContext.contactFromHeader(Node(children: [uncommitted, chip])))
    }

    func testNamedRecipientPhonesAndCommaNamesRemainDistinctFromAddresses() {
        typealias Node = MessagesContext.HeaderNode
        let to = Node(role: "AXTextField", identifier: "To:")
        let phone = Node(role: "AXPopUpButton", description: "Morgan, +1 (202) 555-0148, Not registered")
        let surname = Node(role: "AXPopUpButton", description: "Chen, Riley")
        XCTAssertEqual(MessagesContext.contactFromHeader(Node(children: [to, phone, surname])), "Morgan, Chen, Riley")
        let email = Node(role: "AXPopUpButton", description: "Chen, Riley, riley@example.invalid")
        XCTAssertEqual(MessagesContext.contactFromHeader(Node(children: [to, email])), "Chen, Riley")
    }

    func testCommittedRecipientsPinNewMessageDraftsWithoutReadingHistory() {
        typealias Node = MessagesContext.HeaderNode
        let to = Node(role: "AXTextField", identifier: "To:")
        let chip = Node(role: "AXPopUpButton", description: "flow-demo@example.invalid, Not registered")
        let draft = Node(children: [to, chip])
        XCTAssertEqual(MessagesContext.contactFromHeader(draft), "flow-demo@example.invalid")
        let serialized = Node(role: "AXTextField", identifier: "To:", description: "To:", value: "To:\u{FFFC}flow-demo@example.invalid")
        XCTAssertEqual(MessagesContext.contactFromHeader(Node(children: [serialized, chip])), "flow-demo@example.invalid")
        var editing = serialized
        editing.value += " another@example.invalid"
        XCTAssertNil(MessagesContext.contactFromHeader(Node(children: [editing, chip])))
        XCTAssertEqual(MessagesContext.contactFromHeader(Node(children: [to, chip, Node(role: "AXPopUpButton", description: "Alex")])), "flow-demo@example.invalid, Alex")
        XCTAssertNil(MessagesContext.contactFromHeader(Node(children: [Node(role: "AXTextField", identifier: "To:", value: "another recipient"), chip])))
        XCTAssertNil(MessagesContext.contactFromHeader(Node(children: [to])))
        for identifier in ["ConversationList", "TranscriptCollectionView", "MessageEntryView", "messageBodyField"] {
            XCTAssertNil(MessagesContext.contactFromHeader(Node(identifier: identifier, children: [draft])))
        }
        XCTAssertEqual(MessagesContext.contactFromHeader(Node(identifier: "ConversationTitle", description: "Alex")), "Alex")
    }

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
