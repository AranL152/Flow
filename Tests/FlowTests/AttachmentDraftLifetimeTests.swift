import XCTest
@testable import Flow

final class AttachmentDraftLifetimeTests: XCTestCase {
    func testPopupClosesOnlyAfterAnObservedDraftClears() {
        var lifetime = AttachmentDraftLifetime()
        XCTAssertFalse(lifetime.observe(hasContent: false), "An initially empty attachment-only draft is valid")
        XCTAssertFalse(lifetime.observe(hasContent: false))
        XCTAssertFalse(lifetime.observe(hasContent: true))
        XCTAssertFalse(lifetime.observe(hasContent: false))
        XCTAssertTrue(lifetime.observe(hasContent: false))
    }

    func testEditsReplacementUnreadableAndOtherConversationDoNotDismiss() {
        var lifetime = AttachmentDraftLifetime()
        XCTAssertFalse(lifetime.observe(hasContent: true))
        XCTAssertFalse(lifetime.observe(hasContent: false))
        XCTAssertFalse(lifetime.observe(hasContent: nil), "An unreadable/other-conversation frame is not Send")
        XCTAssertFalse(lifetime.observe(hasContent: false))
        XCTAssertFalse(lifetime.observe(hasContent: true), "An attachment replacement or edit keeps the popup")
        XCTAssertFalse(lifetime.observe(hasContent: false))
    }
}
