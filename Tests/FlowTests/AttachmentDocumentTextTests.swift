import AppKit
import PDFKit
import XCTest
@testable import Flow

final class AttachmentDocumentTextTests: XCTestCase {
    @MainActor
    func testReportTopicMustBeConsecutiveOnOnePage() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let exact = directory.appendingPathComponent("Exact.pdf")
        let scattered = directory.appendingPathComponent("Scattered.pdf")
        let acrossPages = directory.appendingPathComponent("Across pages.pdf")
        let alternative = directory.appendingPathComponent("Alternative.pdf")
        try pdf(["Quarterly Report (Q2 2026)"], at: exact)
        try pdf(["Quarterly earnings grew. Annual report Q2 2026"], at: scattered)
        try pdf(["Quarterly", "Report Q2 2026"], at: acrossPages)
        try pdf(["Quarterly Report (Q1 2026)"], at: alternative)
        let found = try await AttachmentDocumentTextIndex(cacheDirectory: nil).search(
            "quarterly report from Q2 2026", urls: [exact, scattered, acrossPages, alternative])
        XCTAssertEqual(found.map(\.filename), ["Exact.pdf", "Alternative.pdf"])
        XCTAssertEqual(found[0].matchedDocumentText, ["quarterly", "report", "q2", "2026"])
        XCTAssertEqual(found[1].matchedDocumentText, ["quarterly", "report", "2026"])
        XCTAssertTrue(AttachmentDocumentText.containsPhrase(["quarterly", "report"],
            in: AttachmentDocumentText.words("QUARTERLY\nReport")))
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowDocuments-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func pdf(_ pages: [String], at url: URL, scanned: Bool = false) throws {
        if scanned {
            let document = PDFDocument()
            for (number, text) in pages.enumerated() {
                let image = NSImage(size: NSSize(width: 1200, height: 600))
                image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
                text.draw(in: NSRect(x: 60, y: 100, width: 1080, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
                image.unlockFocus(); document.insert(PDFPage(image: image)!, at: number)
            }
            XCTAssertTrue(document.write(to: url)); return
        }
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(in: NSRect(x: 60, y: 100, width: 1080, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: url)
    }

    private func pptx(at url: URL, slide: String = "Quarterly revenue increased", extra: String? = nil, image: Data? = nil) throws {
        let parts = url.deletingLastPathComponent().appendingPathComponent("parts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parts) }
        func write(_ text: String, _ name: String) throws {
            let target = parts.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        try write(#"<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rSecond"/><p:sldId id="257" r:id="rFirst"/></p:sldIdLst></p:presentation>"#, "ppt/presentation.xml")
        try write(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rSecond" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/><Relationship Id="rFirst" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>"#, "ppt/_rels/presentation.xml.rels")
        for (number, text) in [(1, "Welcome to the team"), (2, slide)] {
            try write("<p:sld xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><p:cSld><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:cSld></p:sld>", "ppt/slides/slide\(number).xml")
        }
        if let extra { try write(extra, "ppt/slides/slide3.xml") }
        if let image {
            try write(#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><a:blip r:embed="photo"/></p:cSld></p:sld>"#, "ppt/slides/slide2.xml")
            try write(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="photo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/></Relationships>"#, "ppt/slides/_rels/slide2.xml.rels")
            try FileManager.default.createDirectory(at: parts.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)
            try image.write(to: parts.appendingPathComponent("ppt/media/image1.png"))
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path, "ppt"]; process.currentDirectoryURL = parts
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }

    @MainActor
    func testPDFContentOnSecondPageWithGenericFilenameAndPersistentCache() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Document 01.pdf")
        try pdf(["Team update", "Quarterly revenue grew 25 percent"], at: file)
        let cache = directory.appendingPathComponent("cache"), index = AttachmentDocumentTextIndex(cacheDirectory: directory.appendingPathComponent("cache"))
        let found = try await index.search("mentioning quarterly revenue", urls: [file])
        XCTAssertEqual(found.map(\.filename), ["Document 01.pdf"])
        XCTAssertEqual(found.first?.matchDescription, "Matches: \"quarterly revenue\" · Page 2")
        let restarted = AttachmentDocumentTextIndex(cacheDirectory: cache)
        let warm = try await restarted.search("quarterly revenue", urls: [file])
        XCTAssertEqual(warm.count, 1)
        let stats = await restarted.statistics
        XCTAssertEqual(stats.cacheHits, 1); XCTAssertEqual(stats.extractions, 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent("text-v1.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    @MainActor
    func testScannedPDFUsesRealVisionOCR() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Scan 01.pdf")
        try pdf(["Quarterly revenue\nNorth America sales"], at: file, scanned: true)
        XCTAssertTrue((PDFDocument(url: file)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let found = try await index.search("quarterly revenue", urls: [file])
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.matchedLocation, "Page 1")
    }

    func testPPTXReadsSlideTextAndUsesPresentationOrder() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Presentation 01.pptx")
        try pptx(at: file)
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let found = try await index.search("about quarterly revenue", urls: [file])
        XCTAssertEqual(found.map(\.filename), [file.lastPathComponent])
        XCTAssertEqual(found.first?.matchDescription, "Matches: \"quarterly revenue\" · Slide 1")
        let partial = try await index.search("quarterly losses", urls: [file])
        XCTAssertTrue(partial.isEmpty)
    }

    @MainActor
    func testPPTXRecognizesWordsInsideReferencedSlideImage() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Image deck.pptx")
        let image = NSImage(size: NSSize(width: 1200, height: 600))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
        "Quarterly revenue\nNorth America sales".draw(in: NSRect(x: 60, y: 100, width: 1080, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bytes = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try pptx(at: file, image: bytes)
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let found = try await index.search("quarterly revenue", urls: [file])
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.matchedLocation, "Slide 1")
    }

    @MainActor
    func testChangedDeletedAndLinkedDocumentsDoNotReuseCachedContent() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Document.pdf"), link = directory.appendingPathComponent("Link.pdf")
        try pdf(["Quarterly revenue"], at: file)
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let original = try await index.search("quarterly revenue", urls: [file])
        XCTAssertEqual(original.count, 1)
        try pdf(["Inventory management completed"], at: file)
        let changed = try await index.searchResult("quarterly revenue", urls: [file])
        XCTAssertTrue(changed.matches.isEmpty)
        XCTAssertEqual(changed.checkedURLs, [file.standardizedFileURL], "A fresh negative read must supersede stale Spotlight content")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = try await index.search("inventory", urls: [link])
        XCTAssertTrue(linked.isEmpty)
        try FileManager.default.removeItem(at: file)
        let deleted = try await index.search("inventory", urls: [file])
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertThrowsError(try original[0].validate())
    }

    func testMalformedAndEntityXMLCannotBecomeMatches() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Malformed.pptx")
        try pptx(at: file, slide: "<broken>")
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let malformed = try await index.search("welcome", urls: [file])
        XCTAssertTrue(malformed.isEmpty)
        try FileManager.default.removeItem(at: file)
        try pptx(at: file, extra: #"<!DOCTYPE s [<!ENTITY stolen SYSTEM "file:///etc/passwd">]><s>&stolen;</s>"#)
        let entity = try await index.search("root", urls: [file])
        XCTAssertTrue(entity.isEmpty)
    }

    func testCancellationAndExpiredBudgetDoNotReadOrCacheDocuments() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Presentation.pptx")
        try pptx(at: file)
        let index = AttachmentDocumentTextIndex(cacheDirectory: nil)
        let expired = try await index.search("revenue", urls: [file], budget: 0)
        XCTAssertTrue(expired.isEmpty)
        let task = Task { try await index.search("revenue", urls: [file]) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled document search succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let stats = await index.statistics; XCTAssertEqual(stats.extractions, 0)
    }
}
