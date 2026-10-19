import AppKit
import ApplicationServices
import AVFoundation
import Flow
@testable import FlowApp

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func composer(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 22 else { return nil }
    if attribute(element, kAXIdentifierAttribute) as? String == "messageBodyField" { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = composer(in: child, depth: depth + 1) { return found }
    }
    return nil
}

private func process(_ arguments: [String], capture: Bool = false) throws -> (Process, Pipe?) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: arguments[0]); task.arguments = Array(arguments.dropFirst())
    let pipe = capture ? Pipe() : nil
    if let pipe { task.standardOutput = pipe }
    try task.run()
    return (task, pipe)
}

private func fnTap() {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)
        event?.type = .flagsChanged; event?.flags = down ? .maskSecondaryFn : []
        event?.post(tap: .cghidEventTap); usleep(80000)
    }
}

/// Native New Message preserves the previous addressed draft. Never clear it,
/// type Return, or use a real recipient for an automated voice check.
@MainActor
private func newTestDraft(_ messages: NSRunningApplication) async throws {
    func failure(_ text: String) -> NSError { NSError(domain: "Flow.VoiceReview", code: 2, userInfo: [NSLocalizedDescriptionKey: text]) }
    let root = AXUIElementCreateApplication(messages.processIdentifier)
    func findRecipient(_ element: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
        guard depth < 18 else { return nil }
        if attribute(element, kAXIdentifierAttribute) as? String == "To:" { return element }
        if ["messageBodyField", "ConversationList", "TranscriptCollectionView"].contains(attribute(element, kAXIdentifierAttribute) as? String ?? "") { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = findRecipient(child, depth + 1) { return found }
        }
        return nil
    }
    let oldWindows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let oldField = oldWindows.compactMap({ composer(in: $0) }).first,
       AXEditMonitorService.textValueIncludingEmpty(oldField)?.isEmpty == false,
       Flow(dbPath: ":memory:").activeMessagesContact == nil {
        throw failure("Address the existing draft before making a new one; its text was left unchanged.")
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
    key(45, flags: .maskCommand)
    let release = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)
    release?.type = .flagsChanged; release?.flags = []; release?.post(tap: .cghidEventTap)
    try await Task.sleep(for: .milliseconds(400))
    guard let recipient = findRecipient(root),
          (attribute(recipient, kAXValueAttribute) as? String ?? "").isEmpty else {
        throw failure("New Message did not expose an empty recipient field. No text was cleared.")
    }
    let address = "flow-voice-check-\(UUID().uuidString.lowercased())@example.invalid"
    guard AXUIElementSetAttributeValue(recipient, kAXValueAttribute as CFString, address as CFString) == .success else {
        throw failure("Could not set the test recipient.")
    }
    AXUIElementSetAttributeValue(recipient, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    key(48)
    try await Task.sleep(for: .milliseconds(400))
}

@main
struct RecordAdaptiveVoice {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run() }
            catch { fputs("Voice test failed: \(error.localizedDescription)\n", stderr) }
            NSApplication.shared.terminate(nil)
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
        func failure(_ text: String) -> NSError { NSError(domain: "Flow.VoiceReview", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        let folder = URL(fileURLWithPath: value("--output"))
        let speech = URL(fileURLWithPath: value("--speech"))
        let duration = Double(value("--duration"))!
        let native = args.contains("--native")
        let logURL = native ? URL(fileURLWithPath: value("--app-log")) : nil
        guard AXIsProcessTrusted(), let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
            throw failure("Existing Accessibility access and Messages are required; no permission request was made.")
        }
        if native {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.flow.flow").contains(where: { $0.bundleURL?.lastPathComponent == "Flow Attachments.app" }) else {
                throw failure("The installed Flow Attachments app must already be running.")
            }
        }
        messages.activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(350))
        if args.contains("--new-test-draft") { try await newTestDraft(messages) }
        let root = AXUIElementCreateApplication(messages.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let field = windows.compactMap({ composer(in: $0) }).first,
              AXEditMonitorService.textValueIncludingEmpty(field) == "",
              AXEditMonitorService.attachmentCount(in: field) == 0 else {
            throw failure("Open an empty Messages draft. Existing text and attachments are never cleared.")
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let raw = attribute(field, kAXPositionAttribute), let dimensions = attribute(field, kAXSizeAttribute) {
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(raw as! AXValue, .cgPoint, &point); AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
            point.x += 24; point.y += max(4, size.height - 14)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        try await Task.sleep(for: .milliseconds(180))
        guard let focused = AXEditMonitorService.getFocusedTextElement(pid: messages.processIdentifier), CFEqual(focused, field) else {
            throw failure("Could not focus the message body safely.")
        }
        // Click establishes native focus, then put the caret precisely at the
        // end. A coordinate click alone can land inside the first word.
        var caret = CFRange(location: (AXEditMonitorService.textValueIncludingEmpty(field)! as NSString).length, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, caretValue) == .success else {
            throw failure("Could not position the draft cursor safely.")
        }
        let (volumeTask, volumePipe) = try process(["/usr/bin/osascript", "-e", "output volume of (get volume settings)", "-e", "output muted of (get volume settings)"], capture: true)
        let volumeText = String(decoding: volumePipe!.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        volumeTask.waitUntilExit()
        // Query separately: osascript prints only the last expression's result.
        let (levelTask, levelPipe) = try process(["/usr/bin/osascript", "-e", "output volume of (get volume settings)"], capture: true)
        let level = Int(String(decoding: levelPipe!.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        levelTask.waitUntilExit()
        let muted = volumeText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        defer {
            if let (restore, _) = try? process(["/usr/bin/osascript", "-e", "set volume output volume \(level)", "-e", muted ? "set volume with output muted" : "set volume without output muted"]) {
                restore.waitUntilExit()
            }
        }
        let state: AppState? = native ? nil : AppState()
        defer { state?.cleanup() }
        let baselineLog = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        func freshLog() -> String {
            guard let logURL else { return "" }
            return String(((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").dropFirst(baselineLog.count))
        }
        let movie = folder.appendingPathComponent("recording.mov")
        guard !FileManager.default.fileExists(atPath: movie.path) else { throw failure("Recording already exists.") }
        let (video, _) = try process(["/usr/sbin/screencapture", "-v", "-g", "-R0,380,1512,570", "-V\(Int(duration + 16))", movie.path])
        let began = Date()
        var updates: [[String: Any]] = [], captions: [[String: Any]] = []
        var last = "", lastCaption = "", minimum: Float = 1, maximum: Float = 0
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(began)
                if let text = AXEditMonitorService.textValueIncludingEmpty(field), text != last {
                    updates.append(["seconds": elapsed, "characters": text.count, "change": text.count - last.count])
                    last = text
                }
                if let state {
                    if state.liveTranscript != lastCaption {
                        captions.append(["seconds": elapsed, "characters": state.liveTranscript.count]); lastCaption = state.liveTranscript
                    }
                    if state.isRecording { minimum = min(minimum, state.smoothedAudioLevel); maximum = max(maximum, state.smoothedAudioLevel) }
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { observer.cancel() }
        try await Task.sleep(for: .milliseconds(600))
        let recordingRequested = Date().timeIntervalSince(began)
        if let state { state.startRecording() } else { fnTap() }
        let micDeadline = Date().addingTimeInterval(12)
        while state?.engine.isRecording != true && !freshLog().contains("engine.startRecording:") {
            guard Date() < micDeadline else { throw failure("Microphone did not become ready.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        let microphoneReady = Date().timeIntervalSince(began)
        try await Task.sleep(for: .milliseconds(350))
        let (unmute, _) = try process(["/usr/bin/osascript", "-e", "set volume output volume 45", "-e", "set volume without output muted"])
        unmute.waitUntilExit()
        let speechStart = Date().timeIntervalSince(began)
        let (player, _) = try process(["/usr/bin/afplay", speech.path])
        while player.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        let stopped = Date().timeIntervalSince(began)
        if let state { state.stopRecording() } else { fnTap() }
        var processingFinished: Double?
        while video.isRunning {
            let finished = state.map { !$0.isRecording && !$0.isProcessing } ?? freshLog().contains("[ATTACHMENT] Final staging finished:")
            if processingFinished == nil && finished { processingFinished = Date().timeIntervalSince(began) }
            try await Task.sleep(for: .milliseconds(50))
        }
        observer.cancel(); await observer.value
        let finalCount = AXEditMonitorService.textValueIncludingEmpty(field)?.count ?? -1
        let cloudUpdates = freshLog().components(separatedBy: "\n").filter { $0.contains("[LIVE CAPTION] Cloud update:") }
        let deviceUpdates = freshLog().components(separatedBy: "\n").filter { $0.contains("[LIVE CAPTION] On-device update:") }
        let finalRealtime = freshLog().contains("real-time transcript: true")
        let asrSource = freshLog().components(separatedBy: "\n")
            .last(where: { $0.contains("[ASR] Final source: ") })?
            .components(separatedBy: "[ASR] Final source: ").last ?? "unknown"
        let captionPattern = try NSRegularExpression(pattern: #"\[LIVE CAPTION\] (Cloud|On-device) update: ([0-9]+) characters at ([0-9.]+) seconds"#)
        let log = freshLog() as NSString
        let nativeCaptions: [[String: Any]] = captionPattern.matches(in: log as String, range: NSRange(location: 0, length: log.length)).map {
            ["source": log.substring(with: $0.range(at: 1)),
             "characters": Int(log.substring(with: $0.range(at: 2))) ?? 0,
             "seconds": (Double(log.substring(with: $0.range(at: 3))) ?? 0) + recordingRequested]
        }
        let report: [String: Any] = ["scope": native ? "Installed native app, actual helper Fn events, physical microphone and real cloud inference." : "Production AppState in an isolated diagnostic host with in-memory history; real microphone, real cloud inference, production HUD and actual Messages insertion. Not the installed bundle or helper.",
            "native": native, "microphone_ready_seconds": microphoneReady, "speech_start_seconds": speechStart,
            "native_cloud_caption_updates": cloudUpdates.count, "native_final_realtime_transcript": finalRealtime,
            "native_on_device_caption_updates": deviceUpdates.count,
            "native_asr_source": asrSource,
            "native_caption_updates": nativeCaptions,
            "first_native_caption_after_speech_seconds": nativeCaptions.first.map { ($0["seconds"] as! Double) - speechStart } ?? -1,
            "native_caption_updates_before_stop": nativeCaptions.filter { ($0["seconds"] as! Double) < stopped }.count,
            "stop_seconds": stopped, "processing_finished_seconds": processingFinished ?? -1,
            "stop_to_processing_finished_seconds": processingFinished.map { $0 - stopped } ?? -1,
            "first_draft_change_after_speech_seconds": updates.first.map { ($0["seconds"] as! Double) - speechStart } ?? -1,
            "draft_updates": updates, "caption_updates": captions,
            "draft_updates_before_stop": updates.filter { ($0["seconds"] as! Double) < stopped }.count,
            "audio_level_minimum": native ? NSNull() : minimum as Any, "audio_level_maximum": native ? NSNull() : maximum as Any,
            "final_characters": finalCount, "attachments_after": AXEditMonitorService.attachmentCount(in: field) ?? -1,
            "error": native ? NSNull() : (state?.errorMessage ?? "") as Any, "processing_completed": processingFinished != nil,
            "send_generated": false, "movie_saved": FileManager.default.fileExists(atPath: movie.path),
            "privacy": "Private recording and raw timing points stay local. No Send events or user draft clearing."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("timing.json"))
        print("Voice review finished; draft updates=\(updates.count), processing completed=\(processingFinished != nil)")
    }
}
