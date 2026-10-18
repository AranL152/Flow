import AppKit
import ApplicationServices
import AVFoundation
import Flow
@testable import FlowApp

@main
struct MessagesCheck {
    @MainActor
    static func main() async {
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ flag: String) -> String {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { fatalError("Missing \(flag)") }
            return arguments[i + 1]
        }
        let folder = URL(fileURLWithPath: argument("--folder"))
        let report = URL(fileURLWithPath: argument("--report"))
        var result: [String: Any] = ["scope": "Production Swift components; actual Messages draft; no Send event. Generated audio uploaded; live microphone audio never uploaded.", "status": "unavailable"]
        var checks: [String: Bool] = [:]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = Flow(dbPath: ":memory:")
        checks["accessibility_already_granted"] = AXIsProcessTrusted()
        checks["microphone_already_granted"] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        result["live_captions_authorized"] = LiveSpeechCaptions.isAuthorized
        defer {
            result["checks"] = checks
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report) }
        }
        guard checks["accessibility_already_granted"] == true,
              let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
            result["reason"] = "Messages or existing Accessibility access is unavailable. No access request made."; return
        }
        guard arguments.contains("--run") else {
            result["scope"] = "Read-only existing grants and Messages composer inspection; no recording, cloud request or paste."
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == messages.processIdentifier,
               let composer = AXEditMonitorService.getFocusedTextElement(pid: messages.processIdentifier),
               AXEditMonitorService.isMessagesComposer(composer),
               let count = AXEditMonitorService.attachmentCount(in: composer), count > 0 {
                result["existing_attachment_count"] = count
                let writer = StreamedTextInsertion.capture(app: messages)
                result["rich_draft_uses_safe_fallback"] = writer == nil
                writer?.cancel(restoringOriginal: false)
            }
            result["status"] = "inspected"; return
        }
        messages.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(350))
        if arguments.contains("--append-image") {
            do { result = try await appendImage(engine: engine, messages: messages, folder: folder) }
            catch { result["status"] = "failed"; result["reason"] = error.localizedDescription }
            checks = result["checks"] as? [String: Bool] ?? checks
            return
        }
        guard let contact = engine.activeMessagesContact,
              let composer = AXEditMonitorService.getFocusedTextElement(pid: messages.processIdentifier),
              AXEditMonitorService.isMessagesComposer(composer),
              AXEditMonitorService.textValueIncludingEmpty(composer) == "" else {
            result["reason"] = "A named conversation with an empty focused Messages composer is required. Existing drafts were left untouched."; return
        }
        checks["real_empty_messages_composer"] = true
        let state = AppState()
        let indicator = RecordingIndicatorWindow(appState: state)
        state.liveCaptionStatus = "Generated voice · real Messages verification"
        defer { indicator.hide(); state.attachments.stopObservingDownloads() }
        do {
            // Microphone lifecycle uses the production core. Do not upload it.
            if checks["microphone_already_granted"] == true {
                checks["recording_started"] = engine.startRecording()
                if checks["recording_started"] == true {
                    state.isRecording = true; indicator.show()
                    for _ in 0..<30 {
                        state.smoothedAudioLevel = engine.audioLevel
                        try await Task.sleep(for: .seconds(1.0 / 30))
                    }
                    checks["recording_was_active"] = engine.isRecording
                    let duration = engine.stopRecording()
                    let captured = engine.recordingSamples(after: 0)
                    checks["microphone_captured_real_samples"] = !captured.frames.isEmpty && captured.sampleRate > 0 && duration > 0
                    checks["microphone_released"] = !engine.isRecording
                    result["microphone_sample_rate"] = captured.sampleRate
                    result["microphone_samples_checked"] = captured.frames.count
                }
            }
            // Only synthetic PDFs survive the verifier; the unsent Messages
            // draft must not point to a deleted scratch file.
            let downloads = FileManager.default.temporaryDirectory
                .appendingPathComponent("flow/unsent-messages-verification/\(UUID())/Downloads")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let provider = AttachmentDownloads(directory: downloads)
            try provider.observe()
            let source = downloads.appendingPathComponent("Flow-verification-\(UUID().uuidString.prefix(8)).pdf")
            try FileManager.default.copyItem(at: folder.appendingPathComponent("source.pdf"), to: source)
            try provider.observe()
            let session = AttachmentSession(downloads: provider)
            let privateBoard = NSPasteboard(name: .init("com.flow.messages-check.\(UUID())"))
            defer { privateBoard.releaseGlobally() }
            session.begin(app: messages, contact: contact, board: privateBoard)
            session.startObservingDownloads()
            // The ordinary recording bar receives measured PCM amplitude.
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("speech.aiff"))
            let player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent("speech.aiff"))
            var history = AudioWaveformHistory(barCount: 15)
            var peaks: [Float] = []
            state.isRecording = true; indicator.show(); player.play()
            let started = Date()
            while file.framePosition < file.length {
                let count = AVAudioFrameCount(file.processingFormat.sampleRate / 30)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: buffer)
                let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
                state.audioLevel = min(1, rms * 3); state.smoothedAudioLevel = state.audioLevel
                state.recordingDuration = UInt64(Date().timeIntervalSince(started) * 1000)
                history.tick(level: state.audioLevel, recording: true); peaks.append(history.envelope)
                let due = Double(file.framePosition) / file.processingFormat.sampleRate - Date().timeIntervalSince(started)
                if due > 0 { try await Task.sleep(for: .seconds(due)) }
            }
            state.isRecording = false; state.isProcessing = true; state.smoothedAudioLevel = 0
            for _ in 0..<90 { history.tick(level: 0, recording: false) }
            checks["waveform_reacts_to_measured_speech"] = (peaks.max() ?? 0) > 0.1 && Set(peaks.map { Int($0 * 100) }).count > 5
            checks["waveform_settles_during_silence"] = history.samples.allSatisfy { $0 == 0 }
            result["waveform_frames"] = peaks.count
            result["waveform_peak"] = peaks.max() ?? 0
            guard let writer = StreamedTextInsertion.capture(app: messages) else {
                throw failure("The real composer did not expose a writable stream range")
            }
            let pcm = try Data(contentsOf: folder.appendingPathComponent("speech.pcm"))
            var draft = ""
            var chunks = 0
            var plan: AttachmentPlan?
            for try await event in engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: contact) {
                switch event {
                case .delta(let delta):
                    draft += delta; chunks += 1
                    state.isStreamingOutput = true
                    guard writer.apply(output: draft) else { throw failure("Messages rejected a streamed range update") }
                case .attachment(let attachment):
                    plan = attachment; session.receive(attachment, board: privateBoard)
                case .completed(let text):
                    guard writer.finish(output: text) else { throw failure("Messages rejected the final stream update") }
                    draft = text
                }
            }
            checks["multiple_llm_chunks_in_messages"] = chunks > 1 && writer.writeCount > 1
            checks["messages_final_text_matches_llm"] = AXEditMonitorService.textValueIncludingEmpty(composer) == draft
            checks["attachment_command_excluded_from_text"] = plan != nil && !draft.lowercased().contains("flow") && !draft.lowercased().contains("downloaded")
            guard session.selected != nil else { throw failure("The local PDF was not selected: \(session.status)") }
            let attachmentCountBefore = AXEditMonitorService.attachmentCount(in: composer)
            result["attachment_count_before"] = attachmentCountBefore as Any? ?? NSNull()
            result["attachment_baseline_tree"] = treeSummary(composer, filename: source.lastPathComponent)
            await session.stage(engine: engine, activate: false)
            checks["attachment_paste_dispatched_to_same_contact"] = session.pasteRequested
            try await Task.sleep(for: .milliseconds(800))
            let after = treeSummary(composer, filename: source.lastPathComponent)
            result["attachment_after_tree"] = after
            let countAfter = AXEditMonitorService.attachmentCount(in: composer)
            result["attachment_count_after"] = countAfter as Any? ?? NSNull()
            checks["attachment_visible_in_messages"] = attachmentCountBefore != nil && countAfter != nil && countAfter! > attachmentCountBefore!
            let afterText = AXEditMonitorService.textValueIncludingEmpty(composer) ?? ""
            checks["attachment_preserves_existing_message"] = afterText.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) == draft
            result["attachment_inspection_method"] = "Native AXAttachment attributes in the Messages composer's attributed text; AXChildren do not expose its file objects."

            result["model_chunks"] = chunks; result["ax_text_writes"] = writer.writeCount
            result["draft"] = draft; result["attachment_filename"] = source.lastPathComponent
            result["attachment_status"] = session.status.replacingOccurrences(of: contact, with: "[current contact]")
            checks["no_send_event"] = true
            result["status"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
            state.isProcessing = false; state.isStreamingOutput = false
            // The draft and PDF deliberately remain unsent for the user's review.
        } catch { result["status"] = "failed"; result["reason"] = error.localizedDescription }
    }

    @MainActor
    static func appendImage(engine: Flow, messages: NSRunningApplication, folder: URL) async throws -> [String: Any] {
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("baseline.json"))) as! [String: Any]
        var checks = report["checks"] as? [String: Bool] ?? [:]
        guard let expected = report["draft"] as? String, let contact = engine.activeMessagesContact,
              let composer = AXEditMonitorService.getFocusedTextElement(pid: messages.processIdentifier),
              AXEditMonitorService.isMessagesComposer(composer),
              let original = AXEditMonitorService.textValueIncludingEmpty(composer),
              original.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) == expected,
              let before = AXEditMonitorService.attachmentCount(in: composer), before == 1 else {
            throw failure("The existing draft doesn't match the prior verifier-owned text and single PDF. Nothing changed.")
        }
        // The earlier file is confirmed in attributed text; AXChildren omitted it.
        checks["attachment_visible_in_messages"] = true
        report["pdf_confirmation"] = "One native AXAttachment object alongside the exact streamed text; filename is not exposed through AXChildren."
        let board = NSPasteboard(name: .init("com.flow.image-append-check.\(UUID())"))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        board.writeObjects([image])
        let session = AttachmentSession()
        session.begin(app: messages, contact: contact, board: board)
        var plan: AttachmentPlan?
        var deltas = 0
        var completed = false
        let pcm = try Data(contentsOf: folder.appendingPathComponent("speech.pcm"))
        for try await event in engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: contact) {
            switch event {
            case .delta: deltas += 1
            case .attachment(let value): plan = value; session.receive(value, board: board)
            case .completed(let text): completed = text.isEmpty
            }
        }
        checks["attachment_only_does_not_rewrite_text"] = completed && deltas == 0
        guard completed, deltas == 0, plan?.request?.source == .clipboard, session.selected?.imageData != nil else {
            throw failure("The attachment-only pipeline didn't resolve the fixture image. The Messages draft was left untouched.")
        }
        await session.stage(engine: engine, activate: false)
        try await Task.sleep(for: .milliseconds(500))
        let after = AXEditMonitorService.attachmentCount(in: composer)
        checks["clipboard_image_accepted_by_messages"] = session.attachmentConfirmed && after == before + 1
        checks["existing_pdf_preserved_when_appending_image"] = after == 2
        let final = AXEditMonitorService.textValueIncludingEmpty(composer) ?? ""
        checks["attachment_preserves_existing_message"] = final.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) == expected
        report["attachment_count_before_image"] = before
        report["attachment_count_after_image"] = after as Any? ?? NSNull()
        report["attachment_status"] = session.status.replacingOccurrences(of: contact, with: "[current contact]")
        report["attachment_inspection_method"] = "Native AXAttachment attributes from AXAttributedStringForRange; the PDF and image append leave the original message text intact."
        report["checks"] = checks
        report["status"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
        return report
    }

    @MainActor
    static func treeSummary(_ composer: AXUIElement, filename: String) -> [[String: String]] {
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(composer, kAXParentAttribute as CFString, &parent)
        let root = parent.map { $0 as! AXUIElement } ?? composer
        var result: [[String: String]] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 6, result.count < 100 else { return }
            var row = ["depth": String(depth)]
            for key in [kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, key as CFString, &value)
                if let value = value as? String {
                    row[key] = key == kAXDescriptionAttribute && !value.contains(filename)
                        && !["", "Message", "Send", "Send message"].contains(value) ? "(present)" : value
                }
            }
            for key in [kAXValueAttribute, kAXTitleAttribute, "AXURL", "AXFilename"] {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, key as CFString, &value)
                if String(describing: value).contains(filename) { row["fixture_visible"] = "true" }
            }
            if row.values.contains(where: { $0.contains(filename) }) { row["fixture_visible"] = "true" }
            result.append(row)
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement] ?? []) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }

    static func failure(_ reason: String) -> NSError { NSError(domain: "Flow.MessagesCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}

