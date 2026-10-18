import AppKit
import Flow
import SwiftUI
@testable import FlowApp

@main
struct ScreenshotOCRCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
            let folder = URL(fileURLWithPath: value("--fixtures"))
            var checks: [String: Bool] = [:]
            var result: [String: Any] = ["scope": "Actual local Apple Vision OCR, Spotlight discovery, persistent cache and production attachment picker. Synthetic screenshots with generic filenames. No cloud API calls, Messages writes, sends or permission requests."]
            do {
                let correct = folder.appendingPathComponent("Screenshot 2026-10-18 at 12.00.00.png")
                let partial = folder.appendingPathComponent("Screenshot 2026-10-18 at 12.01.00.png")
                let unrelated = folder.appendingPathComponent("Screenshot 2026-10-18 at 12.02.00.png")
                try image("Payment error\nCard declined\nError 402", at: correct)
                try image("Payment complete\nReceipt ready", at: partial)
                try image("Database connection timeout", at: unrelated)
                let importer = Process(); importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport"); importer.arguments = ["-i", folder.path]
                try importer.run()
                let spotlight = AttachmentFileSearch()
                var recent: [URL] = []
                for _ in 0..<30 {
                    recent = try await spotlight.recentScreenshots(scopes: [folder])
                    if recent.count == 3 { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                checks["spotlight_discovers_recent_generic_screenshots"] = recent.count == 3
                let filenames = try await spotlight.search("payment error", kind: .image, scopes: [folder])
                checks["filenames_alone_do_not_match"] = filenames.isEmpty
                let cache = folder.appendingPathComponent("cache")
                let index = AttachmentImageTextIndex(cacheDirectory: cache)
                let search = AttachmentSearch(scopes: [folder], index: index)
                let start = Date()
                let matches = try await search.search("showing payment error", kind: .image)
                result["cold_search_seconds"] = Date().timeIntervalSince(start)
                checks["real_pixels_find_correct_screenshot"] = matches.map(\.filename) == [correct.lastPathComponent]
                checks["all_words_required_partial_match_excluded"] = !matches.contains { $0.fileURL == partial }
                checks["candidate_explains_visible_word_match"] = matches.first?.matchDescription == "Text: payment · error"
                let cold = await index.statistics
                checks["real_vision_ran_on_three_images"] = cold.recognitions == 3
                let restarted = AttachmentImageTextIndex(cacheDirectory: cache)
                let warmSearch = AttachmentSearch(scopes: [folder], index: restarted)
                let warmStart = Date()
                let again = try await warmSearch.search("payment error", kind: .image)
                result["warm_search_seconds"] = Date().timeIntervalSince(warmStart)
                let warm = await restarted.statistics
                checks["persistent_cache_avoids_repeat_ocr"] = again.map(\.filename) == matches.map(\.filename) && warm.recognitions == 0 && warm.cacheHits == 3
                let session = AttachmentSession(fileSearch: warmSearch)
                let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"Here is the error.","command":"Flow, find the screenshot showing payment error.","request":{"source":"file_search","kind":"image","query":"showing payment error"}}"#.utf8))
                session.receive(plan)
                for _ in 0..<100 where session.searching { try await Task.sleep(for: .milliseconds(100)) }
                checks["production_session_uses_ocr"] = session.candidates.first?.fileURL == correct && session.candidates.first?.matchedImageText == ["payment", "error"]
                if let match = session.candidates.first { session.choose(match.id) }
                let engine = Flow(dbPath: ":memory:")
                await session.automaticallyStage(engine: engine, insertionUnchanged: true)
                checks["no_messages_target_means_no_paste"] = !session.pasteRequested
                let view = NSHostingView(rootView: AttachmentCard(session: session, engine: engine).frame(width: 360).fixedSize(horizontal: false, vertical: true))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(300))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: value("--snapshot")))
                        checks["native_picker_with_match_reason_rendered"] = true
                    }
                }
                try image("Refund completed successfully", at: correct)
                let updated = try await warmSearch.search("payment error", kind: .image)
                checks["changed_image_invalidates_cached_text"] = updated.isEmpty
                session.dismiss()
                result["matched_filename"] = matches.first?.filename ?? ""
                result["matched_words"] = matches.first?.matchedImageText ?? []
            } catch { result["error"] = error.localizedDescription }
            result["checks"] = checks
            result["passed"] = checks.count == 11 && checks.values.allSatisfy { $0 }
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: value("--report")))
            exit(result["passed"] as? Bool == true ? 0 : 1)
        }
        NSApplication.shared.run()
    }

    @MainActor
    private static func image(_ text: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 1100, height: 420))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 420).fill()
        text.draw(in: NSRect(x: 50, y: 70, width: 1000, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
