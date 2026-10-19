import AppKit
import XCTest
@testable import Flow

final class AttachmentTests: XCTestCase {
    @MainActor
    func testNamedFileAttachmentPreservesFilenameBytesAndURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Business report Q2.pdf")
        let bytes = Data("Original attachment bytes".utf8)
        try bytes.write(to: url)
        let board = NSPasteboard(name: .init("com.flow.test.\(UUID())"))
        defer { board.releaseGlobally() }
        try AttachmentCandidate(fileURL: url, sourceLabel: "Test").write(to: board)
        let data = try XCTUnwrap(board.data(forType: .rtfd))
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        let attachment = try XCTUnwrap(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, url.lastPathComponent)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents, bytes)
        XCTAssertEqual(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], [url])
    }

    func testImageSnapshotSurvivesTextInsertionAndRejectsWrongType() throws {
        let board = NSPasteboard(name: .init("com.flow.test.\(UUID())"))
        defer { board.releaseGlobally() }
        let image = NSImage(size: .init(width: 8, height: 8))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        board.writeObjects([image])
        let snapshot = AttachmentClipboardSnapshot(board: board)
        board.clearContents(); board.setString("LLM draft", forType: .string)
        let candidate = try snapshot.resolve(kind: .image)
        XCTAssertNotNil(candidate.imageData)
        XCTAssertThrowsError(try snapshot.resolve(kind: .pdf))
        try candidate.write(to: board)
        XCTAssertFalse(board.readObjects(forClasses: [NSImage.self])?.isEmpty ?? true)
        let composer = NSTextView(frame: .zero)
        composer.isRichText = true; composer.importsGraphics = true
        XCTAssertTrue(composer.readSelection(from: board))
        XCTAssertGreaterThan(composer.textStorage?.length ?? 0, 0)
        XCTAssertNotNil(composer.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testDownloadsUseObservedArrivalFilterTypesAndRejectChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.pdf")
        try Data("old fixture".utf8).write(to: old)
        let provider = AttachmentDownloads(directory: directory)
        let clock = Date()
        try provider.observe(now: clock)
        let recent = directory.appendingPathComponent("deck.pdf")
        try Data("recent fixture".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: recent.path)
        try Data("partial".utf8).write(to: directory.appendingPathComponent("new.pdf.crdownload"))
        try Data("zip".utf8).write(to: directory.appendingPathComponent("newer.zip"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.pdf"), withDestinationURL: old)
        try provider.observe(now: clock.addingTimeInterval(2))
        XCTAssertThrowsError(try provider.candidates(kind: .pdf, now: clock.addingTimeInterval(2.5)))
        let candidates = try provider.candidates(kind: .pdf, now: clock.addingTimeInterval(4))
        XCTAssertEqual(candidates.map(\.filename), ["deck.pdf"])
        XCTAssertFalse(candidates[0].approximateRecency)
        try candidates[0].validate()
        try Data("changed fixture content".utf8).write(to: recent)
        XCTAssertThrowsError(try candidates[0].validate())
    }

    func testColdStartRequiresReviewAndCopiedFilesAreRevalidated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invoice.pdf")
        try Data("pdf fixture".utf8).write(to: file)
        let provider = AttachmentDownloads(directory: directory)
        let clock = Date()
        try provider.observe(now: clock)
        XCTAssertTrue(try XCTUnwrap(provider.candidates(kind: .pdf, now: clock.addingTimeInterval(2)).first).approximateRecency)
        let board = NSPasteboard(name: .init("com.flow.test.\(UUID())"))
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let snapshot = AttachmentClipboardSnapshot(board: board)
        XCTAssertThrowsError(try snapshot.resolve(kind: .image))
        let candidate = try snapshot.resolve(kind: .pdf)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try candidate.write(to: board))
    }
}
