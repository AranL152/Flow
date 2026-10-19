import AppKit
import Flow
import PDFKit
import SwiftUI
@testable import FlowApp

/// Real Spotlight + PDFKit + Vision + ZIP/XML readers and the production picker.
/// Synthetic fixtures only; no cloud, permission requests or Messages writes.
@main
struct DocumentContentCheck {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
            let folder = URL(fileURLWithPath: value("--fixtures"))
            var checks: [String: Bool] = [:]
            var result: [String: Any] = ["scope": "Synthetic, generically named PDF and PPTX files; real local Spotlight discovery, PDF text, scanned PDF OCR, slide XML and embedded slide-image OCR, persistent cache and the production attachment picker. No API calls, audio, permission requests or Messages writes."]
            do {
                let text = folder.appendingPathComponent("Document 01.pdf"), scanned = folder.appendingPathComponent("Document 02.pdf")
                try pdf(["Welcome to the review", "Cobalt nebula\nProject milestones"], at: text)
                let image = NSImage(size: NSSize(width: 1200, height: 600))
                image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
                "Cobalt nebula\nProject milestones".draw(in: NSRect(x: 60, y: 100, width: 1080, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
                image.unlockFocus()
                let scan = PDFDocument(); scan.insert(PDFPage(image: image)!, at: 0); guard scan.write(to: scanned) else { throw failure("Cannot write scan fixture.") }
                let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                try pptx(folder.appendingPathComponent("Presentation 01.pptx"), image: nil)
                try pptx(folder.appendingPathComponent("Presentation 02.pptx"), image: png)
                try pdf(["Cobalt inventory\nUnrelated results"], at: folder.appendingPathComponent("Document 03.pdf"))
                let importer = Process(); importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport"); importer.arguments = ["-i", folder.path]
                try importer.run(); importer.waitUntilExit()
                let discovery = AttachmentFileSearch()
                var documents: [URL] = []
                for _ in 0..<40 {
                    documents = try await discovery.recentDocuments(kind: .any, scopes: [folder])
                    if documents.count == 5 { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                checks["spotlight_discovers_five_generic_documents"] = documents.count == 5
                let names = try await discovery.search("cobalt nebula", kind: .any, scopes: [folder])
                checks["filenames_alone_do_not_match"] = names.isEmpty
                var spotlight: [AttachmentCandidate] = []
                for _ in 0..<20 {
                    spotlight = try await discovery.documentContents("mentioning cobalt nebula", kind: .any, scopes: [folder])
                    if spotlight.contains(where: { $0.fileURL == text }) { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                checks["real_spotlight_content_finds_text_pdf"] = spotlight.contains { $0.fileURL == text }
                let cache = folder.appendingPathComponent("cache"), index = AttachmentDocumentTextIndex(cacheDirectory: folder.appendingPathComponent("cache"))
                let search = AttachmentSearch(scopes: [folder], documentIndex: index)
                let start = Date()
                // Direct reading deliberately bypasses Spotlight's content results
                // to prove scanned/image-only cases are independently searchable.
                let direct = try await index.search("mentioning cobalt nebula", urls: documents)
                result["cold_direct_seconds"] = Date().timeIntervalSince(start)
                checks["direct_readers_find_four_content_matches"] = direct.count == 4
                checks["partial_word_match_excluded"] = !direct.contains { $0.filename == "Document 03.pdf" }
                checks["pdf_text_explains_second_page"] = direct.first { $0.fileURL == text }?.matchedLocation == "Page 2"
                checks["scanned_pdf_is_image_only"] = (PDFDocument(url: scanned)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                checks["scanned_pdf_found_by_real_ocr"] = direct.first { $0.fileURL == scanned }?.matchedLocation == "Page 1"
                checks["slide_text_and_image_ocr_found"] = direct.filter { $0.fileURL?.pathExtension == "pptx" && $0.matchedLocation == "Slide 2" }.count == 2
                let pdfs = try await search.search("mentioning cobalt nebula", kind: .pdf)
                let slides = try await search.search("containing cobalt nebula", kind: .presentation)
                checks["integrated_pdf_content_search_and_type_filter"] = pdfs.count == 2 && pdfs.allSatisfy { $0.fileURL?.pathExtension == "pdf" }
                checks["integrated_slide_content_search_and_type_filter"] = slides.count == 2 && slides.allSatisfy { $0.fileURL?.pathExtension == "pptx" }
                let restarted = AttachmentDocumentTextIndex(cacheDirectory: cache)
                let warmStart = Date()
                let warm = try await restarted.search("cobalt nebula", urls: documents)
                let stats = await restarted.statistics
                result["warm_direct_seconds"] = Date().timeIntervalSince(warmStart)
                checks["cache_survives_restart_without_reopening_documents"] = warm.count == 4 && stats.extractions == 0 && stats.cacheHits == 5
                let session = AttachmentSession(fileSearch: AttachmentSearch(scopes: [folder], documentIndex: restarted))
                let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"Here is the deck.","command":"Flow, find the deck mentioning cobalt nebula.","request":{"source":"file_search","kind":"presentation","query":"mentioning cobalt nebula"}}"#.utf8))
                session.receive(plan)
                for _ in 0..<150 where session.searching { try await Task.sleep(for: .milliseconds(100)) }
                checks["production_session_resolves_both_decks"] = session.candidates.count == 2 && !session.searching
                checks["picker_explains_content_and_slide"] = session.candidates.allSatisfy { $0.matchDescription == "Matches: \"cobalt nebula\" · Slide 2" }
                let engine = Flow(dbPath: ":memory:")
                let view = NSHostingView(rootView: AttachmentCard(session: session, engine: engine).frame(width: 360).fixedSize(horizontal: false, vertical: true))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds), let path = args.firstIndex(of: "--snapshot") {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[path + 1]))
                    checks["native_picker_rendered"] = true
                }
                session.dismiss()
                try pdf(["Inventory planning has changed"], at: text)
                let changed = try await restarted.search("cobalt nebula", urls: [text])
                checks["changed_pdf_invalidates_persistent_cache"] = changed.isEmpty
                result["matches"] = direct.map { ["filename": $0.filename, "reason": $0.matchDescription ?? ""] }
            } catch { result["error"] = error.localizedDescription }
            result["checks"] = checks; result["passed"] = checks.count == 16 && checks.values.allSatisfy { $0 }
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: value("--report")))
            exit(result["passed"] as? Bool == true ? 0 : 1)
        }
        NSApplication.shared.run()
    }

    @MainActor private static func pdf(_ pages: [String], at url: URL) throws {
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for text in pages {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(in: NSRect(x: 60, y: 100, width: 1080, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: url)
    }

    private static func pptx(_ url: URL, image: Data?) throws {
        let parts = url.deletingLastPathComponent().appendingPathComponent("parts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parts) }
        func write(_ text: String, _ path: String) throws {
            let file = parts.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write(#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>"#, "[Content_Types].xml")
        try write(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#, "_rels/.rels")
        try write(#"<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>"#, "ppt/presentation.xml")
        try write(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/></Relationships>"#, "ppt/_rels/presentation.xml.rels")
        for number in 1...2 {
            let text = number == 1 ? "Welcome to the review" : image == nil ? "Cobalt nebula project milestones" : ""
            let picture = number == 2 && image != nil ? #"<p:pic><p:blipFill><a:blip r:embed="photo"/></p:blipFill></p:pic>"# : ""
            try write("<p:sld xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><p:cSld><p:spTree><p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>\(picture)</p:spTree></p:cSld></p:sld>", "ppt/slides/slide\(number).xml")
        }
        if let image {
            try write(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="photo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/></Relationships>"#, "ppt/slides/_rels/slide2.xml.rels")
            try FileManager.default.createDirectory(at: parts.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)
            try image.write(to: parts.appendingPathComponent("ppt/media/image1.png"))
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.arguments = ["-qr", url.path, "."]; process.currentDirectoryURL = parts
        try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw failure("Cannot write PPTX fixture.") }
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "Flow.DocumentCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
