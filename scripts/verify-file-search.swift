import AppKit
import Flow
import SwiftUI
@testable import FlowApp

@main
struct SearchCheck {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let args = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
            let text = value("--query")
            let report = URL(fileURLWithPath: value("--report"))
            var checks: [String: Bool] = [:]
            var result: [String: Any] = ["scope": "Real local Spotlight index and native attachment selection; synthetic files only. No Messages paste or Send. No permission requests."]
            do {
                let search = AttachmentFileSearch()
                let files = try await search.search(text, kind: .pdf)
                checks["real_home_scope_finds_indexed_fixtures"] = files.count == 2
                checks["requested_type_is_respected"] = files.allSatisfy { $0.fileURL?.pathExtension == "pdf" }
                result["filenames"] = files.map(\.filename)
                let plan = try JSONDecoder().decode(AttachmentPlan.self, from: JSONSerialization.data(withJSONObject: [
                    "message": "Here's the file.", "command": "Flow, find my \(text) PDF.",
                    "request": ["source": "file_search", "kind": "pdf", "query": text]
                ]))
                let session = AttachmentSession()
                session.receive(plan)
                for _ in 0..<80 where session.searching { try await Task.sleep(for: .milliseconds(100)) }
                checks["native_session_resolves_search"] = session.candidates.count == 2 && !session.searching
                checks["selection_is_required"] = session.needsChoice && session.selected == nil && !session.pasteRequested
                if let candidate = session.candidates.first {
                    session.choose(candidate.id)
                    checks["selection_exposes_preview"] = session.selected?.filename == candidate.filename
                    let engine = Flow(dbPath: ":memory:")
                    await session.automaticallyStage(engine: engine, insertionUnchanged: true)
                    checks["no_target_means_no_auto_paste"] = !session.pasteRequested
                    let view = NSHostingView(rootView: AttachmentCard(session: session, engine: engine).padding(16).background(FW.background))
                    view.frame = NSRect(x: 0, y: 0, width: 500, height: 850)
                    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = view
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(500))
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try png.write(to: URL(fileURLWithPath: value("--snapshot")))
                            checks["native_preview_rendered"] = true
                        }
                    }
                }
                session.searchText = text + " sketch"
                session.searchFiles()
                for _ in 0..<80 where session.searching { try await Task.sleep(for: .milliseconds(100)) }
                checks["multiple_filename_words_refine_results"] = session.candidates.count == 1 && session.candidates.first?.filename.contains("sketch") == true
                checks["single_match_still_requires_selection"] = session.needsChoice && session.selected == nil && !session.pasteRequested
                session.dismiss()
                checks["dismiss_clears_search_and_selection"] = session.plan == nil && session.selected == nil && !session.searching
                let task = Task { @MainActor in try await search.search(text, kind: .pdf) }
                await Task.yield()
                task.cancel()
                do { _ = try await task.value; checks["cancel_stops_pending_search"] = false }
                catch is CancellationError { checks["cancel_stops_pending_search"] = true }
                catch { checks["cancel_stops_pending_search"] = false }
            } catch { result["error"] = error.localizedDescription }
            result["checks"] = checks
            result["passed"] = checks.count == 11 && checks.values.allSatisfy { $0 }
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            exit(result["passed"] as? Bool == true ? 0 : 1)
        }
        app.run()
    }
}
