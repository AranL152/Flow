import AppKit
import Flow
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import FlowApp

@MainActor
final class RipplePreview: ObservableObject {
    let state = AppState()
    let attachments: AttachmentSession
    let folder: URL
    let output: URL
    @Published var running = false
    @Published var reduceMotion = false
    @Published var status = "Ready"
    var capture: (() -> CGImage?)?
    private var results: AttachmentPreviewWindow?
    private var frames: [CGImage] = []
    private let sentence = "Here's the issue. Flow, find the screenshot showing payment error."

    init(folder: URL, output: URL) {
        self.folder = folder; self.output = output
        attachments = AttachmentSession(fileSearch: AttachmentSearch(scopes: [folder], index: AttachmentImageTextIndex(cacheDirectory: nil)))
    }

    func run() async {
        guard !running else { return }
        running = true; status = "Playing preview…"; frames = []; reduceMotion = false; attachments.dismiss(); results?.hide()
        state.isRecording = false; state.isProcessing = false; state.liveTranscript = ""
        var checks: [String: Bool] = [:]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try fixtures()
            let importer = Process(); importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport"); importer.arguments = ["-i", folder.path]; try importer.run()
            let recordStart = Date()
            state.isRecording = true; state.smoothedAudioLevel = 0.35; state.liveTranscript = "Here's the issue."
            let recording = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, let image = self.capture?(), self.frames.count < 100 { self.frames.append(image) }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
            defer { recording.cancel() }
            try await Task.sleep(for: .milliseconds(300))
            for word in ["Flow,", "find", "the", "screenshot", "showing", "payment", "error."] {
                state.liveTranscript += " " + word
                state.recordingDuration = UInt64(Date().timeIntervalSince(recordStart) * 1000)
                try await Task.sleep(for: .milliseconds(150))
            }
            savePNG("command-ripple-listening.png")
            try await Task.sleep(for: .milliseconds(200))
            savePNG("command-ripple-listening-dots.png")
            checks["listening_dots_preview_rendered"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("command-ripple-listening-dots.png").path)
            checks["recording_cue_has_no_command_highlight"] = FlowCommandCaption.detect(in: state.liveTranscript, isRecording: true) == nil
            checks["explicit_cue_detected"] = FlowCommandCaption.detect(in: state.liveTranscript)?.command == "Flow, find the screenshot showing payment error."
            state.isRecording = false; state.isProcessing = true
            // A stale audio sample must not show a microphone waveform in this phase.
            state.smoothedAudioLevel = 0.9
            try await Task.sleep(for: .milliseconds(250)); savePNG("command-ripple-active.png")
            try await Task.sleep(for: .seconds(LiquidCommandText.rippleDuration + LiquidCommandText.settleDuration / 2 - 0.25))
            savePNG("command-ripple-settling.png")
            checks["settling_synced_glow_preview_rendered"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("command-ripple-settling.png").path)
            try await Task.sleep(for: .seconds(LiquidCommandText.settleDuration / 2 + 0.1)); savePNG("command-ripple-settled.png")
            let plan = try JSONDecoder().decode(AttachmentPlan.self, from: Data(#"{"message":"Here's the issue.","command":"Flow, find the screenshot showing payment error.","request":{"source":"file_search","kind":"image","query":"showing payment error"}}"#.utf8))
            attachments.receive(plan)
            checks["status_uses_real_search_state"] = attachments.searching
            for _ in 0..<60 where attachments.searching { try await Task.sleep(for: .milliseconds(50)) }
            checks["real_local_ocr_produces_handoff_candidates"] = attachments.candidates.count == 2 && attachments.candidates.allSatisfy { $0.matchedImageText == ["payment", "error"] }
            try await Task.sleep(for: .milliseconds(150)); savePNG("command-ripple-found.png")
            recording.cancel()
            writeGIF()
            // Alternate test fixtures must never change the visible demo state.
            checks.merge(await verifyHiddenVariants()) { _, new in new }
            checks.merge(await verifyWindowVisibility()) { _, new in new }
            results = AttachmentPreviewWindow(session: attachments, engine: state.engine)
            attachments.onDismiss = { [weak self] in self?.results?.hide() }
            results?.show(candidateCount: attachments.candidates.count, isSearch: true)
            checks["animation_exported"] = frames.count >= 20 && FileManager.default.fileExists(atPath: output.appendingPathComponent("command-ripple.gif").path)
            status = "Preview complete · Replay to watch again"
        } catch { status = error.localizedDescription }
        let report: [String: Any] = ["scope": "Native production caption/ripple views with labelled simulated captions and real local OCR. No microphone recording, cloud API calls or Messages changes. Still images and GIF require visual review.",
            "checks": checks, "frames": frames.count, "frame_interval_ms_target": 50, "status": checks.count == 13 && checks.values.allSatisfy { $0 } ? "ready" : "failed"]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("command-ripple-verification.json"))
        running = false
    }

    private func verifyHiddenVariants() async -> [String: Bool] {
        let variant = RipplePreview(folder: folder, output: output)
        variant.status = "Offscreen verification"
        let host = NSHostingView(rootView: RipplePreviewView(model: variant)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(FW.background))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 350)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        variant.capture = { [weak host] in
            guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.cgImage
        }
        var checks: [String: Bool] = [:]
        variant.reduceMotion = true
        variant.state.isRecording = false; variant.state.isProcessing = true; variant.state.liveTranscript = sentence
        try? await Task.sleep(for: .milliseconds(250))
        variant.savePNG("command-ripple-reduced-motion.png")
        checks["reduced_motion_preview_rendered"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("command-ripple-reduced-motion.png").path)
        variant.state.isRecording = true; variant.state.isProcessing = false; variant.state.liveTranscript = "I use Flow every day."
        try? await Task.sleep(for: .milliseconds(150))
        variant.savePNG("command-ripple-ordinary-mention.png")
        checks["ordinary_mention_is_not_a_command"] = FlowCommandCaption.detect(in: variant.state.liveTranscript) == nil
        variant.state.isRecording = false; variant.state.isProcessing = true
        variant.state.liveTranscript = "Here's the issue. Flow, find the screenshot showing " + String(repeating: "payment error details ", count: 12)
        try? await Task.sleep(for: .milliseconds(150))
        variant.savePNG("command-ripple-long-command.png")
        checks["long_command_preview_rendered"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("command-ripple-long-command.png").path)
        return checks
    }

    private func verifyWindowVisibility() async -> [String: Bool] {
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let indicator = RecordingIndicatorWindow(appState: state, attachments: attachments)
        guard let window = NSApplication.shared.windows.first(where: { $0.title == "Flow · Recording" && !existing.contains(ObjectIdentifier($0)) }) else { return [:] }
        // Exercise real AppKit visibility offscreen, beneath the desktop, so
        // regression checks cannot flash a second indicator over the live demo.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        indicator.show()
        try? await Task.sleep(for: .milliseconds(450))
        let frame = window.frame
        var opaque = window.alphaValue >= 0.98, stable = true
        for _ in 0..<4 {
            indicator.show()
            opaque = opaque && window.alphaValue >= 0.98
            stable = stable && window.frame == frame
            try? await Task.sleep(for: .milliseconds(40))
        }
        indicator.hide()
        try? await Task.sleep(for: .milliseconds(100))
        indicator.show()
        try? await Task.sleep(for: .milliseconds(500))
        let latestRequestWins = window.isVisible && window.alphaValue >= 0.98
        indicator.hide()
        try? await Task.sleep(for: .milliseconds(450))
        window.isReleasedWhenClosed = false
        window.close()
        return ["repeated_show_keeps_indicator_opaque": opaque,
                "repeated_show_keeps_indicator_position": stable,
                "hide_then_show_preserves_latest_visibility": latestRequestWins]
    }

    private func savePNG(_ name: String) {
        guard let image = capture?(), let target = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(target, image, nil); CGImageDestinationFinalize(target)
    }

    private func writeGIF() {
        guard !frames.isEmpty, let target = CGImageDestinationCreateWithURL(output.appendingPathComponent("command-ripple.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(target, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(target, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        CGImageDestinationFinalize(target)
    }

    private func fixtures() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in [("Screenshot 2026-10-18 01.png", "Payment error\nCard declined"), ("Screenshot 2026-10-18 02.png", "Payment error\nPlease try again")] {
            let image = NSImage(size: NSSize(width: 1000, height: 350)); image.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 350).fill()
            text.draw(in: NSRect(x: 40, y: 70, width: 920, height: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            image.unlockFocus()
            try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        }
    }
}

struct RipplePreviewView: View {
    @ObservedObject var model: RipplePreview
    var body: some View {
        VStack(spacing: 10) {
            Text("Flow command effect").font(.headline)
            Text("Simulated captions · no microphone or API calls").font(.caption).foregroundStyle(.secondary)
            RecordingIndicatorView(attachmentSession: model.attachments).environmentObject(model.state)
                .environment(\.flowReduceMotion, model.reduceMotion)
                .frame(width: 500, height: 190)
            HStack {
                Button("Replay") { Task { await model.run() } }.disabled(model.running)
                Toggle("Reduce Motion", isOn: $model.reduceMotion).toggleStyle(.checkbox).disabled(model.running)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 520).background(FW.background)
    }
}

@main
struct RipplePreviewRunner {
    @MainActor private static var window: NSWindow?
    @MainActor private static var model: RipplePreview?
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String { args[args.firstIndex(of: key)! + 1] }
        let model = RipplePreview(folder: URL(fileURLWithPath: value("--fixtures")), output: URL(fileURLWithPath: value("--output")))
        Self.model = model
        let host = NSHostingView(rootView: RipplePreviewView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 552, height: 350)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Flow · Command effect preview"; window.contentView = host; window.isReleasedWhenClosed = false
        window.level = .floating; window.center(); window.orderFrontRegardless(); Self.window = window
        model.capture = { [weak host] in
            guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap); return bitmap.cgImage
        }
        Task { await model.run() }
        NSApplication.shared.run()
    }
}
