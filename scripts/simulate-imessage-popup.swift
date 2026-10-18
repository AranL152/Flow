import AppKit
import ApplicationServices
import AVFoundation
import Flow
@testable import FlowApp

/// The real Flow attachment panel, bound to the currently open Messages composer.
/// An attachment-only voice command preserves any existing draft and files.
@MainActor
final class MessagesPopupSimulation {
    private let engine = Flow(dbPath: ":memory:")
    private let session = AttachmentSession()
    private var preview: AttachmentPreviewWindow?
    private var player: AVAudioPlayer?

    func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String { arguments[arguments.firstIndex(of: key)! + 1] }
        let folder = URL(fileURLWithPath: value("--folder"))
        let report = URL(fileURLWithPath: value("--report"))
        var result: [String: Any] = ["scope": "Generated voice through the real Rust/cloud parser; production search popup bound to actual Messages. Existing draft is preserved. No Send event or automatic paste."]
        var checks: [String: Bool] = [:]
        defer {
            result["checks"] = checks
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: report, options: .atomic)
            }
        }
        guard AXIsProcessTrusted(), let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
            result["status"] = "unavailable"
            result["reason"] = "Messages and existing Accessibility access are required. No permission request was made."
            return
        }
        messages.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(350))
        guard let contact = engine.activeMessagesContact, let composer = findComposer(in: AXUIElementCreateApplication(messages.processIdentifier)) else {
            result["status"] = "unavailable"
            result["reason"] = "Open a named Messages conversation with a composer, then rerun. Existing drafts were left untouched."
            return
        }
        _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(150))
        let original = AXEditMonitorService.textValueIncludingEmpty(composer)
        let originalAttachments = AXEditMonitorService.attachmentCount(in: composer)
        session.begin(app: messages, contact: contact)
        checks["real_messages_target_captured"] = session.targetMatches(engine: engine)
        guard checks["real_messages_target_captured"] == true else {
            result["status"] = "unavailable"; result["reason"] = "The current Messages composer could not be bound; nothing was pasted."
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent("search.aiff"))
            player?.play()
            try await Task.sleep(for: .seconds(player?.duration ?? 4))
            let pcm = try Data(contentsOf: folder.appendingPathComponent("search.pcm"))
            var plan: AttachmentPlan?
            var generatedText = ""
            for try await event in engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: contact) {
                switch event {
                case .attachment(let attachment): plan = attachment
                case .delta(let text): generatedText += text
                case .completed: break
                }
            }
            checks["voice_resolves_filename_search"] = plan?.request?.source == .fileSearch
            checks["attachment_only_does_not_generate_message"] = generatedText.isEmpty
            guard let plan, plan.request?.source == .fileSearch else { throw failure("The voice command did not resolve a filename search.") }
            session.receive(plan)
            preview = AttachmentPreviewWindow(session: session, engine: engine)
            session.onDismiss = { [weak self] in self?.preview?.hide() }
            preview?.show(candidateCount: 0, isSearch: true)
            for _ in 0..<80 where session.searching { try await Task.sleep(for: .milliseconds(100)) }
            checks["matching_files_visible"] = !session.candidates.isEmpty
            checks["selection_still_required"] = session.needsChoice && session.selected == nil && !session.pasteRequested
            checks["existing_draft_preserved"] = original != nil && original == AXEditMonitorService.textValueIncludingEmpty(composer)
            checks["existing_attachments_preserved"] = originalAttachments != nil && originalAttachments == AXEditMonitorService.attachmentCount(in: composer)
            result["command"] = plan.command
            result["candidate_filenames"] = session.candidates.map(\.filename)
            result["status"] = checks.values.allSatisfy { $0 } ? "ready" : "review"
        } catch {
            result["status"] = "failed"; result["reason"] = error.localizedDescription
        }
    }

    private func findComposer(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 18 else { return nil }
        var identifier: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXIdentifierAttribute as CFString, &identifier) == .success,
           identifier as? String == "messageBodyField" { return root }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children) == .success,
           let elements = children as? [AXUIElement] {
            for element in elements {
                if let composer = findComposer(in: element, depth: depth + 1) { return composer }
            }
        }
        return nil
    }

    private func failure(_ text: String) -> NSError { NSError(domain: "Flow.MessagesPopup", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

@main
struct MessagesPopupRunner {
    @MainActor private static var simulation: MessagesPopupSimulation?
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        simulation = MessagesPopupSimulation()
        Task { await simulation?.run() }
        NSApplication.shared.run()
    }
}
