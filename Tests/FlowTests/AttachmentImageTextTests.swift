import AppKit
import XCTest
@testable import Flow

final class AttachmentImageTextTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FlowOCR-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func image(_ text: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 1100, height: 420))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 420).fill()
        text.draw(in: NSRect(x: 50, y: 70, width: 1000, height: 300), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    @MainActor
    func testRealVisionFindsWordsInsideGenericFilenameAndCachesAcrossRestart() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let correct = directory.appendingPathComponent("Screenshot 2026-10-18 01.png")
        let partial = directory.appendingPathComponent("Screenshot 2026-10-18 02.png")
        let unrelated = directory.appendingPathComponent("Screenshot 2026-10-18 03.png")
        try image("Payment error\nCard declined\nError 402", at: correct)
        try image("Payment complete\nReceipt ready", at: partial)
        try image("Database connection timeout", at: unrelated)
        let urls = [correct, partial, unrelated]
        let cache = directory.appendingPathComponent("cache")
        let index = AttachmentImageTextIndex(cacheDirectory: cache)
        let found = try await index.search("showing payment error", urls: urls)
        XCTAssertEqual(found.map(\.filename), [correct.lastPathComponent])
        XCTAssertEqual(found.first?.matchedImageText, ["payment", "error"])
        XCTAssertEqual(found.first?.matchDescription, "Text: payment · error")
        XCTAssertFalse(correct.lastPathComponent.lowercased().contains("payment"))
        let cold = await index.statistics
        XCTAssertEqual(cold.recognitions, 3)
        let restarted = AttachmentImageTextIndex(cacheDirectory: cache)
        let again = try await restarted.search("payment error", urls: urls)
        XCTAssertEqual(again.map(\.filename), found.map(\.filename))
        let warm = await restarted.statistics
        XCTAssertEqual(warm.recognitions, 0); XCTAssertEqual(warm.cacheHits, 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent("text-v1.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    @MainActor
    func testChangedDeletedAndLinkedImagesNeverReuseStaleText() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Screenshot generic.png")
        try image("Payment error", at: url)
        let index = AttachmentImageTextIndex(cacheDirectory: nil)
        let first = try await index.search("payment error", urls: [url])
        XCTAssertEqual(first.count, 1)
        try image("Refund completed successfully", at: url)
        let changed = try await index.search("payment error", urls: [url])
        XCTAssertTrue(changed.isEmpty)
        let link = directory.appendingPathComponent("Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let linked = try await index.search("refund", urls: [link])
        XCTAssertTrue(linked.isEmpty)
        try FileManager.default.removeItem(at: url)
        let removed = try await index.search("refund", urls: [url])
        XCTAssertTrue(removed.isEmpty)
        let stats = await index.statistics
        XCTAssertEqual(stats.recognitions, 2)
    }

    func testVisibleWordQueriesAreLiteralAndIgnoreOnlySearchPhrasing() throws {
        XCTAssertEqual(try AttachmentImageTextIndex.searchWords("showing the payment error"), ["payment", "error"])
        XCTAssertEqual(try AttachmentImageTextIndex.searchWords("with Café total 42%"), ["cafe", "total", "42"])
        for invalid in ["the screenshot showing text", "/etc/passwd", "payment\nerror"] {
            XCTAssertThrowsError(try AttachmentImageTextIndex.searchWords(invalid))
        }
    }

    @MainActor
    func testOldHiddenCorruptAndNonimageFilesAreSkipped() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("Screenshot old.png")
        let hidden = directory.appendingPathComponent(".Screenshot hidden.png")
        let corrupt = directory.appendingPathComponent("Screenshot broken.png")
        let text = directory.appendingPathComponent("Screenshot file.txt")
        try image("Payment error", at: old); try image("Payment error", at: hidden)
        try Data("invalid png".utf8).write(to: corrupt); try Data("Payment error".utf8).write(to: text)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86400)], ofItemAtPath: old.path)
        let index = AttachmentImageTextIndex(cacheDirectory: nil)
        let found = try await index.search("payment error", urls: [old, hidden, corrupt, text])
        XCTAssertTrue(found.isEmpty)
        let stats = await index.statistics
        XCTAssertEqual(stats.recognitions, 0)
    }

    func testCancellationStopsBeforeReadingPixels() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Screenshot cancellation.png")
        try Data([1]).write(to: file)
        let index = AttachmentImageTextIndex(cacheDirectory: nil, recognize: { _ in
            XCTFail("Cancelled search opened an image")
            return "payment error"
        })
        let task = Task { try await index.search("payment error", urls: [file]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
