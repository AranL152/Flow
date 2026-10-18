import AppKit
import ApplicationServices
import AVFoundation
import Flow
@testable import FlowApp

/// Insert only new LLM deltas: existing native attachment objects stay untouched.
/// This demo adapter also works when Messages doesn't expose AXSelectedText.
@MainActor
private final class DemoMessageStream {
    private let app: NSRunningApplication
    private let composer: AXUIElement
    private var expected: String
    private let attachmentCount: Int
    private var output = ""
    private(set) var writes = 0

    init(app: NSRunningApplication, composer: AXUIElement) throws {
        self.app = app; self.composer = composer
        guard let text = AXEditMonitorService.textValueIncludingEmpty(composer),
              let count = AXEditMonitorService.attachmentCount(in: composer) else { throw demoError("Cannot read the existing Messages draft.") }
        expected = text; attachmentCount = count
        var range = CFRange(location: (text as NSString).length, length: 0)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw demoError("Cannot place the cursor after the existing draft.")
        }
    }

    func append(_ delta: String) async throws {
        guard !delta.isEmpty else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(focused, composer),
              AXEditMonitorService.textValueIncludingEmpty(composer) == expected,
              AXEditMonitorService.attachmentCount(in: composer) == attachmentCount else {
            throw demoError("The draft or focus changed. Further insertion stopped.")
        }
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { throw demoError("The Messages selection is unavailable.") }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range), range.length == 0, range.location == (expected as NSString).length else {
            throw demoError("The cursor moved. Further insertion stopped.")
        }
        let text = (output.isEmpty && !expected.isEmpty ? " " : "") + delta
        // Unicode text events avoid Messages' smart-paste spaces between tokens.
        // Control characters are rejected; this path never produces Return/Send.
        guard text.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw demoError("Control characters are unavailable in the native demo stream.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw demoError("Cannot create a text event.") }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.flags = []; up.flags = []
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        let next = expected + text
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(20))
            if let actual = AXEditMonitorService.textValueIncludingEmpty(composer), canonicalQuotes(actual) == canonicalQuotes(next) {
                expected = actual; output += delta; writes += 1
                return
            }
        }
        throw demoError("Messages did not confirm the new text. Further insertion stopped.")
    }
}

private func demoError(_ text: String) -> NSError { NSError(domain: "Flow.FullDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

/// Messages applies smart quotes while typing; acknowledge its equivalent native
/// spelling while keeping every other character and attachment check exact.
private func canonicalQuotes(_ text: String) -> String {
    text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
}

@MainActor
final class FullMessagesDemo {
    private let state = AppState()
    private let session = AttachmentSession()
    private let captions = LiveSpeechCaptions()
    private var preview: AttachmentPreviewWindow?
    private var indicator: RecordingIndicatorWindow?
    private var player: AVAudioPlayer?
    private var results: [[String: Any]] = []
    private var captionUpdates = 0
    private var started = Date()

    func run() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
        let folder = URL(fileURLWithPath: value("--folder"))
        let report = URL(fileURLWithPath: value("--report"))
        started = Date()
        func save(_ status: String, error: String? = nil) {
            var result: [String: Any] = ["status": status, "cases": results,
                "scope": "Generated speech; actual on-device captions and waveform; real cloud LLM chunks typed into actual Messages; production ranking and automatic attachment append followed by candidate popup. No Send event. Screenshot selection uses filenames, not OCR.",
                "seconds": Date().timeIntervalSince(started)]
            if let error { result["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        }
        do {
            guard AXIsProcessTrusted(), let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
                throw demoError("Open Messages with existing Accessibility access. No permission request was made.")
            }
            messages.activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(300))
            let application = AXUIElementCreateApplication(messages.processIdentifier)
            var focusedWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
                  let focusedWindow, let contact = state.engine.activeMessagesContact,
                  let composer = findComposer(in: focusedWindow as! AXUIElement) else {
                throw demoError("A named Messages conversation with a composer is required.")
            }
            let screenshotFolder = URL(fileURLWithPath: value("--fixtures"))
            try makeScreenshots(in: screenshotFolder)
            let index = Process(); index.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport"); index.arguments = ["-i", screenshotFolder.path]
            try index.run()
            try await Task.sleep(for: .seconds(1.2))
            preview = AttachmentPreviewWindow(session: session, engine: state.engine)
            session.onDismiss = { [weak self] in self?.preview?.hide() }
            indicator = RecordingIndicatorWindow(appState: state)
            let selected = value("--kind")
            let kinds = selected == "both" ? ["file", "screenshot"] : [selected]
            for kind in kinds {
                preview?.hide()
                messages.activate(options: [.activateAllWindows])
                try await focusComposer(composer, app: messages)
                guard state.engine.activeMessagesContact == contact else { throw demoError("The Messages conversation changed.") }
                let original = AXEditMonitorService.textValueIncludingEmpty(composer)
                let before = AXEditMonitorService.attachmentCount(in: composer)
                session.begin(app: messages, contact: contact)
                guard session.targetMatches(engine: state.engine) else { throw demoError("The Messages composer changed.") }
                let writer = try DemoMessageStream(app: messages, composer: composer)
                try await speak(kind, folder: folder)
                let pcm = try Data(contentsOf: folder.appendingPathComponent(kind + ".pcm"))
                state.isProcessing = true
                var output = "", chunks = 0
                var plan: AttachmentPlan?
                for try await event in state.engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: contact) {
                    switch event {
                    case .delta(let delta):
                        guard state.engine.activeMessagesContact == contact else { throw demoError("The conversation changed during streaming.") }
                        chunks += 1; output += delta
                        state.isStreamingOutput = true
                        try await writer.append(delta)
                    case .attachment(let request): plan = request
                    case .completed(let final):
                        guard final == output.trimmingCharacters(in: .whitespacesAndNewlines) else { throw demoError("The model stream was not complete.") }
                    }
                }
                guard let plan, plan.request?.source == .fileSearch else { throw demoError("The voice command did not resolve a filename search.") }
                session.receive(plan)
                await session.automaticallyStage(engine: state.engine, insertionUnchanged: true)
                let after = AXEditMonitorService.attachmentCount(in: composer)
                let expectedFile = kind == "file" ? "Orion-review.pdf" : "Orion-dashboard.png"
                let textNow = AXEditMonitorService.textValueIncludingEmpty(composer)
                let checks: [String: Bool] = [
                    "live_captions": captionUpdates > 0,
                    "real_llm_chunks_inserted": chunks > 1 && writer.writes == chunks,
                    "original_draft_preserved": original != nil && textNow.map { canonicalQuotes($0).hasPrefix(canonicalQuotes(original!)) } == true,
                    "original_attachments_plus_one": before != nil && after == before! + 1,
                    "best_filename_selected": session.selected?.filename == expectedFile,
                    "native_attachment_confirmed": session.attachmentConfirmed,
                    "alternatives_available": session.candidates.count >= 2,
                    "command_excluded_from_message": !output.lowercased().contains("flow")]
                state.isProcessing = false; state.isStreamingOutput = false; indicator?.hide()
                preview?.show(candidateCount: session.candidates.count, isSearch: true)
                results.append(["kind": kind, "generated_message": output, "command": plan.command,
                    "caption_updates": captionUpdates, "llm_chunks": chunks, "native_text_writes": writer.writes,
                    "attached_filename": session.selected?.filename ?? "", "candidates": session.candidates.map(\.filename),
                    "checks": checks, "passed": checks.values.allSatisfy { $0 }])
                save("running")
                guard checks.values.allSatisfy({ $0 }) else { throw demoError("A full-demo verification check failed; the current draft was left unsent.") }
                if kind != kinds.last { try await Task.sleep(for: .seconds(7)) }
            }
            save("ready")
        } catch {
            captions.cancel(); player?.stop(); indicator?.hide()
            state.isRecording = false; state.isProcessing = false; state.isStreamingOutput = false
            save("failed", error: error.localizedDescription)
        }
    }

    private func speak(_ name: String, folder: URL) async throws {
        let audioURL = folder.appendingPathComponent(name + ".aiff")
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        captionUpdates = 0; state.liveTranscript = ""; state.isRecording = true; state.isProcessing = false
        captions.onText = { [weak self] text, _ in self?.state.liveTranscript = text; self?.captionUpdates += 1 }
        captions.onStatus = { [weak self] text in self?.state.liveCaptionStatus = text }
        await captions.start()
        guard captions.isListening else { throw demoError(state.liveCaptionStatus) }
        indicator?.show()
        player = try AVAudioPlayer(contentsOf: audioURL); player?.play()
        let start = Date()
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 30))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            captions.append(samples: samples, sampleRate: UInt32(rate))
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
            state.audioLevel = min(1, rms * 3); state.smoothedAudioLevel = state.audioLevel
            state.recordingDuration = UInt64(Date().timeIntervalSince(start) * 1000)
            let due = Double(file.framePosition) / rate - Date().timeIntervalSince(start)
            if due > 0 { try await Task.sleep(for: .seconds(due)) }
        }
        captions.finish(); state.isRecording = false; state.audioLevel = 0; state.smoothedAudioLevel = 0
    }

    private func makeScreenshots(in folder: URL) throws {
        for (filename, notes) in [("Orion-dashboard.png", false), ("Orion-dashboard-notes.png", true)] {
            let image = NSImage(size: NSSize(width: 900, height: 540))
            image.lockFocus()
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 540).fill()
            NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.24, alpha: 1).setFill(); NSRect(x: 0, y: 460, width: 900, height: 80).fill()
            let title = notes ? "ORION / Dashboard notes" : "ORION / Dashboard"
            title.draw(at: NSPoint(x: 35, y: 482), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 27), .foregroundColor: NSColor.white])
            let lines = notes ? ["Review notes", "Traffic increased this week", "Investigate the Tuesday dip", "Prepared for the project review"]
                : ["Project overview", "Active users                       1,284", "Requests today                    24,806", "Service availability              99.9%"]
            for (i, text) in lines.enumerated() {
                text.draw(at: NSPoint(x: 40, y: 398 - i * 68), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: i == 0 ? .semibold : .regular), .foregroundColor: NSColor.darkGray])
            }
            "Synthetic screenshot fixture · Flow demo".draw(at: NSPoint(x: 40, y: 32), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.gray])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw demoError("Cannot prepare the screenshot fixtures.")
            }
            try png.write(to: folder.appendingPathComponent(filename))
        }
    }

    private func findComposer(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 18 else { return nil }
        var identifier: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXIdentifierAttribute as CFString, &identifier) == .success,
           identifier as? String == "messageBodyField" { return root }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            for child in children { if let found = findComposer(in: child, depth: depth + 1) { return found } }
        }
        return nil
    }

    private func focusComposer(_ composer: AXUIElement, app: NSRunningApplication) async throws {
        _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(100))
        if let current = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(current, composer) { return }
        // Some Messages versions leave focus on a wrapper after AXFocused=true.
        // Click the bottom-left text area, away from the Send button on the right.
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(composer, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { throw demoError("Click the Messages text area, then rerun.") }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 80 else {
            throw demoError("The Messages text area could not be located.")
        }
        let point = CGPoint(x: origin.x + 24, y: origin.y + max(4, dimensions.height - 14))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(180))
        guard let current = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(current, composer) else {
            throw demoError("Messages did not focus its text area; no text was inserted.")
        }
    }
}

@main
struct FullMessagesRunner {
    @MainActor private static var demo: FullMessagesDemo?
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        demo = FullMessagesDemo()
        Task { await demo?.run() }
        NSApplication.shared.run()
    }
}
