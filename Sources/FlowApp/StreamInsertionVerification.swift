import AppKit
import ApplicationServices

/// Isolated native AX fixture. Does not open Messages, use production data,
/// install hotkeys, record audio, or send a message.
@MainActor
final class StreamInsertionVerification {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let composer = NSTextView(frame: NSRect(x: 24, y: 50, width: 570, height: 150))

    func run() {
        window.title = "Flow Stream Insertion Verification"
        composer.font = .systemFont(ofSize: 20)
        composer.isRichText = false
        composer.string = "before OLD after"
        composer.setSelectedRange(NSRange(location: 7, length: 3))
        window.contentView?.addSubview(composer)
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(composer)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            try? await Task.sleep(for: .seconds(1))
            var checks: [String: Bool] = [:]
            var reason = ""
            if let writer = StreamedTextInsertion.capture(app: .current) {
                checks["first_delta_writes_selected_range"] = writer.apply(output: "hi ❤️") && composer.string == "before hi ❤️ after"
                try? await Task.sleep(for: .milliseconds(200))
                checks["next_delta_preserves_surrounding_text"] = writer.apply(output: "hi ❤️ Alex") && composer.string == "before hi ❤️ Alex after"
                checks["failed_stream_restores_original_selection"] = writer.cancel(restoringOriginal: true) && composer.string == "before OLD after" && composer.selectedRange() == NSRange(location: 7, length: 3)
                if let writer = StreamedTextInsertion.capture(app: .current) {
                    _ = writer.apply(output: "partial")
                    composer.string = "my edited draft"
                    composer.setSelectedRange(NSRange(location: 15, length: 0))
                    checks["user_edit_blocks_late_tokens"] = !writer.apply(output: "late token") && composer.string == "my edited draft"
                    checks["user_edit_blocks_rollback"] = !writer.cancel(restoringOriginal: true) && composer.string == "my edited draft"
                }
                composer.string = ""; composer.setSelectedRange(NSRange(location: 0, length: 0))
                if let writer = StreamedTextInsertion.capture(app: .current) {
                    checks["complete_draft_written_without_return"] = writer.apply(output: "got a sec") && writer.finish(output: "got a sec to review the slides?") && composer.string == "got a sec to review the slides?"
                }
            } else {
                reason = AXIsProcessTrusted() ? "The fixture did not expose a writable focused AX range" : "Accessibility permission is not granted to this verification app"
            }
            let arguments = ProcessInfo.processInfo.arguments
            let all = checks.count == 6 && checks.values.allSatisfy { $0 }
            let report: [String: Any] = ["kind": "isolated native NSTextView Accessibility integration", "status": checks.isEmpty ? "unavailable" : (all ? "passed" : "failed"), "reason": reason, "checks": checks, "final_draft": composer.string]
            if let index = arguments.firstIndex(of: "--verification-report"), arguments.indices.contains(index + 1),
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            }
            window.title = "Flow Stream Verification · \(checks.isEmpty ? reason : (all ? "Passed" : "Failed"))"
        }
    }
}
