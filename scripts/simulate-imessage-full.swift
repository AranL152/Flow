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
    private let originalLength: Int
    private let attachmentCount: Int
    private var output = ""
    private var pending = ""
    var insertedText: String { output }
    private(set) var largestWrite = 0
    private(set) var writes = 0

    init(app: NSRunningApplication, composer: AXUIElement) throws {
        self.app = app; self.composer = composer
        guard let text = AXEditMonitorService.textValueIncludingEmpty(composer),
              let count = AXEditMonitorService.attachmentCount(in: composer) else { throw demoError("Cannot read the existing Messages draft.") }
        expected = text; originalLength = canonicalQuotes(text).utf16.count; attachmentCount = count
        var range = CFRange(location: (text as NSString).length, length: 0)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw demoError("Cannot place the cursor after the existing draft.")
        }
    }

    func append(_ delta: String) async throws {
        try Task.checkCancellation()
        pending += delta
        // Messages handles tiny Unicode packets more reliably than isolated
        // keystrokes. Keep at most one grapheme waiting between display frames.
        while pending.count >= 2 {
            let frame = String(pending.prefix(2))
            try await insert(frame)
            pending.removeFirst(frame.count)
        }
        if pending.last.map({ ".,!?;:\n".contains($0) }) == true { try await finish() }
    }

    func finish() async throws {
        try Task.checkCancellation()
        guard !pending.isEmpty else { return }
        try await insert(pending)
        pending = ""
    }

    private func insert(_ delta: String) async throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw demoError("Messages lost foreground focus after \(writes) text updates.")
        }
        guard let focused = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier), CFEqual(focused, composer) else {
            throw demoError("The composer lost focus after \(writes) text updates.")
        }
        guard let actual = AXEditMonitorService.textValueIncludingEmpty(composer) else {
            throw demoError("The draft became unreadable after \(writes) text updates. Further insertion stopped.")
        }
        guard canonicalQuotes(actual) == canonicalQuotes(expected) else {
            throw demoError("The draft changed after \(writes) text updates. \(mismatch(expected: expected, observed: actual)) Further insertion stopped.")
        }
        guard AXEditMonitorService.attachmentCount(in: composer) == attachmentCount else {
            throw demoError("Attachments changed after \(writes) text updates (expected \(attachmentCount), observed \(AXEditMonitorService.attachmentCount(in: composer).map(String.init) ?? "unavailable")). Further insertion stopped.")
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
                expected = actual; output += delta; writes += 1; largestWrite = max(largestWrite, delta.count)
                return
            }
        }
        let observedAfterWrite = AXEditMonitorService.textValueIncludingEmpty(composer) ?? ""
        throw demoError("Messages did not confirm text update \(writes + 1). \(mismatch(expected: next, observed: observedAfterWrite)) Further insertion stopped.")
    }

    private func mismatch(expected: String, observed: String) -> String {
        let wanted = Array(canonicalQuotes(expected).utf16), actual = Array(canonicalQuotes(observed).utf16)
        let first = zip(wanted, actual).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(wanted.count, actual.count)
        guard first >= originalLength else { return "The original draft changed." }
        func unit(_ units: [UInt16]) -> String { first < units.count ? String(format: "U+%04X", units[first]) : "end" }
        return "Flow output offset \(first - originalLength): expected \(unit(wanted)), observed \(unit(actual)); lengths \(wanted.count)/\(actual.count)."
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
    private let session: AttachmentSession
    private let captions = LiveSpeechCaptions()
    private let cloudSpeech = CloudSpeechStream()
    private var cloudCaptionReceived = false
    private var preview: AttachmentPreviewWindow?
    private var indicator: RecordingIndicatorWindow?
    private var player: AVAudioPlayer?
    private var results: [[String: Any]] = []
    private var captionUpdates = 0
    private var started = Date()

    init() {
        let args = ProcessInfo.processInfo.arguments
        let scopes = args.firstIndex(of: "--fixtures").flatMap { index in
            args.indices.contains(index + 1) ? [URL(fileURLWithPath: args[index + 1])] : nil
        }
        session = AttachmentSession(fileSearch: AttachmentSearch(scopes: scopes))
    }

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
            indicator = RecordingIndicatorWindow(appState: state, attachments: session)
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
                let stopped = Date()
                let realtimeTranscript = await cloudSpeech.finish()
                let finalizationMs = Date().timeIntervalSince(stopped) * 1000
                var output = "", chunks = 0, rawOutput = "", rawChunks = 0, largestDisplayChunk = 0
                var firstFrame: Date?, lastFrame: Date?
                var plan: AttachmentPlan?
                let queue = AsyncThrowingStream<DictationStreamEvent, Error>.makeStream()
                let receiving = Task { @MainActor in
                    do {
                        for try await event in state.engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: contact, finalTranscript: realtimeTranscript) {
                            if case .delta(let text) = event { rawChunks += 1; rawOutput += text }
                            queue.continuation.yield(event)
                        }
                        queue.continuation.finish()
                    } catch { queue.continuation.finish(throwing: error) }
                }
                defer { receiving.cancel() }
                for try await event in DictationPresentation.smooth(queue.stream) {
                    switch event {
                    case .delta(let delta):
                        guard state.engine.activeMessagesContact == contact else { throw demoError("The conversation changed during streaming.") }
                        chunks += 1; output += delta; largestDisplayChunk = max(largestDisplayChunk, delta.count)
                        if firstFrame == nil { firstFrame = Date() }; lastFrame = Date()
                        state.isStreamingOutput = true
                        try await writer.append(delta)
                    case .attachment(let request): plan = request
                    case .completed(let final):
                        guard final == output.trimmingCharacters(in: .whitespacesAndNewlines) else { throw demoError("The model stream was not complete.") }
                    }
                }
                try await writer.finish()
                guard let plan, plan.request?.source == .fileSearch else { throw demoError("The voice command did not resolve a filename search.") }
                session.receive(plan)
                await session.automaticallyStage(engine: state.engine, insertionUnchanged: true)
                let after = AXEditMonitorService.attachmentCount(in: composer)
                let expectedFile = kind == "file" ? "Orion-review.pdf" : "Orion-dashboard.png"
                let textNow = AXEditMonitorService.textValueIncludingEmpty(composer)
                let initialConfirmed = session.attachmentConfirmed
                var replacementVerified = false
                var replacementDetails: [String: Any] = [:]
                if args.contains("--verify-replacement"), let attached = session.selected,
                   let alternative = session.candidates.first(where: { $0.id != attached.id }),
                   let snapshot = MessagesAttachmentSnapshot.read(composer) {
                    session.choose(alternative.id)
                    await session.stage(engine: state.engine)
                    replacementDetails = ["alternative_confirmed": session.attachmentConfirmed,
                        "alternative_selected": session.attachedID == alternative.id,
                        "count_preserved": AXEditMonitorService.attachmentCount(in: composer) == after,
                        "text_preserved": MessagesAttachmentSnapshot.read(composer)?.text == snapshot.text,
                        "status": session.status.replacingOccurrences(of: contact, with: "[contact]")]
                    let changed = session.attachmentConfirmed && session.attachedID == alternative.id
                        && MessagesAttachmentSnapshot.read(composer)?.text == snapshot.text
                        && AXEditMonitorService.attachmentCount(in: composer) == after
                    // Restore the original demo file through the same production action.
                    session.choose(attached.id)
                    await session.stage(engine: state.engine)
                    replacementVerified = changed && session.attachmentConfirmed && session.attachedID == attached.id
                        && MessagesAttachmentSnapshot.read(composer)?.text == snapshot.text
                        && AXEditMonitorService.attachmentCount(in: composer) == after
                }
                let revealSeconds = lastFrame?.timeIntervalSince(firstFrame ?? Date()) ?? 0
                let minimumRevealSeconds = output.count <= 240 ? Double(max(0, output.count - 1)) * 0.035 : 0.2
                var checks: [String: Bool] = [
                    "live_captions": captionUpdates > 0,
                    "command_effect_detected": FlowCommandCaption.detect(in: state.liveTranscript) != nil,
                    "real_llm_chunks_inserted": rawChunks > 1 && writer.writes > 1 && writer.insertedText == output && rawOutput == output,
                    "paced_display_frames": chunks > 1 && revealSeconds >= minimumRevealSeconds,
                    "small_display_chunks": largestDisplayChunk <= 4,
                    "small_native_writes": writer.largestWrite <= 2,
                    "original_draft_preserved": original != nil && textNow.map { canonicalQuotes($0).hasPrefix(canonicalQuotes(original!)) } == true,
                    "original_attachments_plus_one": before != nil && after == before! + 1,
                    "best_filename_selected": session.selected?.filename == expectedFile,
                    "native_attachment_confirmed": initialConfirmed,
                    "alternatives_available": session.candidates.count >= 2,
                    "command_excluded_from_message": !output.lowercased().contains("flow")]
                if args.contains("--verify-replacement") { checks["alternative_replacement"] = replacementVerified }
                state.isProcessing = false; state.isStreamingOutput = false; indicator?.hide()
                preview?.show(candidateCount: session.candidates.count, isSearch: true)
                try await Task.sleep(for: .milliseconds(200))
                if let view = NSApplication.shared.windows.first(where: { $0.title == "Flow · Attachment" })?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("attachment-popup.png"))
                }
                results.append(["kind": kind, "generated_message": output, "command": plan.command,
                    "used_realtime_cloud_asr": realtimeTranscript != nil, "asr_finalization_ms": finalizationMs,
                    "stop_to_first_display_ms": firstFrame.map { $0.timeIntervalSince(stopped) * 1000 } ?? -1,
                    "caption_updates": captionUpdates, "llm_chunks": rawChunks, "display_frames": chunks, "native_text_writes": writer.writes,
                    "display_reveal_seconds": revealSeconds, "largest_display_chunk": largestDisplayChunk, "largest_native_write": writer.largestWrite,
                    "attached_filename": session.selected?.filename ?? "", "candidates": session.candidates.map(\.filename),
                    "replacement": replacementDetails, "checks": checks, "passed": checks.values.allSatisfy { $0 }])
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
        cloudSpeech.start()
        cloudCaptionReceived = false
        cloudSpeech.onText = { [weak self] text in
            self?.cloudCaptionReceived = true; self?.state.liveTranscript = text; self?.captionUpdates += 1
        }
        cloudSpeech.onFailure = { [weak self] in self?.cloudCaptionReceived = false }
        captions.onText = { [weak self] text, _ in
            guard let self, !self.cloudCaptionReceived else { return }
            self.state.liveTranscript = text; self.captionUpdates += 1
        }
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
            cloudSpeech.append(samples: samples, sampleRate: UInt32(rate))
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
            // Replays may still have this file attached in Messages. Leave the
            // source intact instead of triggering a native attachment refresh.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) { continue }
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
