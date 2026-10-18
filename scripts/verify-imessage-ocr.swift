import AppKit
import ApplicationServices
import Flow
@testable import FlowApp

/// Attachment-only integration check. The intent is supplied locally: no audio,
/// ASR, LLM or API request is simulated or billed by this runner.
@MainActor
final class MessagesOCRCheck {
    private let engine = Flow(dbPath: ":memory:")
    private var session: AttachmentSession?
    private var preview: AttachmentPreviewWindow?

    func run() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
        let folder = URL(fileURLWithPath: value("--fixtures"))
        var result: [String: Any] = ["scope": "Supplied local search intent → actual Spotlight and Apple Vision OCR → production auto-append and candidate replacement in actual Messages. Synthetic screenshots only. No audio, ASR or LLM API calls. No Send event."]
        var checks: [String: Bool] = [:]
        do {
            try fixtures(in: folder)
            let importer = Process(); importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport"); importer.arguments = ["-i", folder.path]
            try importer.run()
            let finder = AttachmentFileSearch()
            for _ in 0..<30 {
                if try await finder.recentScreenshots(scopes: [folder]).count >= 3 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard AXIsProcessTrusted(), let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
                throw failure("Messages and existing Accessibility access are required. No permission request was made.")
            }
            messages.activate(options: [.activateAllWindows]); try await Task.sleep(for: .milliseconds(250))
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(messages.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window, let composer = findComposer(in: window as! AXUIElement), let contact = engine.activeMessagesContact else {
                throw failure("Open a named Messages conversation with a composer.")
            }
            try await focus(composer, app: messages)
            guard let before = MessagesAttachmentSnapshot.read(composer) else { throw failure("Cannot inspect the draft.") }
            var caret = CFRange(location: (before.text as NSString).length, length: 0)
            guard let value = AXValueCreate(.cfRange, &caret),
                  AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, value) == .success else { throw failure("Cannot place the cursor after the draft.") }
            let index = AttachmentImageTextIndex(cacheDirectory: folder.appendingPathComponent("cache"))
            let session = AttachmentSession(fileSearch: AttachmentSearch(scopes: [folder], index: index))
            self.session = session
            session.begin(app: messages, contact: contact)
            let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"","command":"Flow, find the screenshot showing payment error.","request":{"source":"file_search","kind":"image","query":"showing payment error"}}"#.utf8))
            session.receive(plan)
            let start = Date()
            await session.automaticallyStage(engine: engine, insertionUnchanged: true)
            result["search_and_native_paste_seconds"] = Date().timeIntervalSince(start)
            guard let best = session.selected, let after = MessagesAttachmentSnapshot.read(composer) else { throw failure("The screenshot was not selected.") }
            checks["found_visible_words_not_filename"] = best.matchedImageText == ["payment", "error"] && !best.filename.lowercased().contains("payment")
            checks["best_recent_match_auto_appended"] = session.attachmentConfirmed && session.attachedID == best.id
            checks["original_text_preserved"] = after.text.hasPrefix(before.text)
            checks["exactly_one_native_file_added"] = after.items.count == before.items.count + 1
            checks["unrelated_native_files_preserved"] = after.preservesObjects(in: before)
            checks["partial_text_match_excluded"] = session.candidates.count == 2
            if let alternative = session.candidates.first(where: { $0.id != best.id }) {
                session.choose(alternative.id); await session.stage(engine: engine)
                let swapped = MessagesAttachmentSnapshot.read(composer)
                checks["alternative_replaces_only_flows_file"] = session.attachmentConfirmed && session.attachedID == alternative.id
                    && swapped?.text == after.text && swapped?.items.count == after.items.count && swapped?.preservesObjects(in: before) == true
                session.choose(best.id); await session.stage(engine: engine)
                let restored = MessagesAttachmentSnapshot.read(composer)
                checks["original_choice_restored_without_changing_draft"] = session.attachmentConfirmed && session.attachedID == best.id
                    && restored?.text == after.text && restored?.items.count == after.items.count && restored?.preservesObjects(in: before) == true
            }
            preview = AttachmentPreviewWindow(session: session, engine: engine)
            session.onDismiss = { [weak self] in self?.preview?.hide() }
            preview?.show(candidateCount: session.candidates.count, isSearch: true)
            result["matched_filename"] = best.filename
            result["matched_words"] = best.matchedImageText
            result["candidate_filenames"] = session.candidates.map(\.filename)
            let stats = await index.statistics
            result["local_ocr_recognitions"] = stats.recognitions
            result["local_cache_hits"] = stats.cacheHits
        } catch { result["error"] = error.localizedDescription }
        result["checks"] = checks
        result["status"] = checks.count == 8 && checks.values.allSatisfy { $0 } ? "ready" : "failed"
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: value("--report")), options: .atomic)
    }

    private func fixtures(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text, age) in [
            ("Screenshot 2026-10-18 at 12.00.00.png", "Payment error\nCard declined\nError 402", 0.0),
            ("Screenshot 2026-10-18 at 11.59.00.png", "Payment error\nPlease try again", 60.0),
            ("Screenshot 2026-10-18 at 12.01.00.png", "Payment complete\nReceipt ready", 0.0)
        ] {
            let image = NSImage(size: NSSize(width: 1100, height: 420))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 420).fill()
            text.draw(in: NSRect(x: 50, y: 70, width: 1000, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            image.unlockFocus()
            let url = folder.appendingPathComponent(name)
            try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
    }

    private func findComposer(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 18 else { return nil }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
        if value as? String == "messageBodyField" { return element }
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        for child in value as? [AXUIElement] ?? [] { if let found = findComposer(in: child, depth: depth + 1) { return found } }
        return nil
    }

    private func focus(_ composer: AXUIElement, app: NSRunningApplication) async throws {
        _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(100))
        if let current = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(current, composer) { return }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(composer, kAXSizeAttribute as CFString, &size) == .success, let position, let size else { throw failure("Cannot locate the composer.") }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 80 else { throw failure("Cannot locate the composer.") }
        let point = CGPoint(x: origin.x + 24, y: origin.y + max(4, dimensions.height - 14))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(180))
        guard let current = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(current, composer) else { throw failure("Messages did not focus the composer.") }
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "Flow.OCRCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct MessagesOCRRunner {
    @MainActor private static var check: MessagesOCRCheck?
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        check = MessagesOCRCheck()
        Task { await check?.run() }
        NSApplication.shared.run()
    }
}
