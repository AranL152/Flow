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
                let engine = Flow(dbPath: ":memory:")
                let picker = AttachmentPreviewWindow(session: session, engine: engine)
                picker.show(candidateCount: session.candidates.count, isSearch: true)
                try await Task.sleep(for: .milliseconds(300))
                let unselectedHeight = picker.contentSize.height
                checks["unselected_panel_includes_status_hint"] = picker.contentSize.width == 360 && unselectedHeight >= 260
                func snapshot(_ name: String) throws -> Bool {
                    guard let view = app.windows.first(where: { $0.title == "Flow · Attachment" })?.contentView else { return false }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
                    let target = URL(fileURLWithPath: value("--snapshot")).deletingLastPathComponent().appendingPathComponent(name)
                    try png.write(to: target)
                    return true
                }
                checks["unselected_native_preview_rendered"] = try snapshot("file-search-unselected.png")
                if let candidate = session.candidates.first {
                    session.choose(candidate.id)
                    checks["selection_exposes_preview"] = session.selected?.filename == candidate.filename
                    await session.automaticallyStage(engine: engine, insertionUnchanged: true)
                    checks["no_target_means_no_auto_paste"] = !session.pasteRequested
                    try await Task.sleep(for: .milliseconds(300))
                    let selectedHeight = picker.contentSize.height
                    checks["compact_native_panel"] = picker.contentSize.width == 360 && (180...330).contains(selectedHeight)
                    checks["panel_refits_when_hint_disappears"] = unselectedHeight >= selectedHeight + 20
                    result["panel_heights"] = ["unselected": unselectedHeight, "selected": selectedHeight]
                    checks["native_preview_rendered"] = try snapshot("file-search-preview.png")
                }
                picker.hide()
                var draftContent: Bool? = true
                let sendPicker = AttachmentPreviewWindow(session: session, engine: engine, draftHasContent: { draftContent })
                sendPicker.show(candidateCount: session.candidates.count, isSearch: true)
                try await Task.sleep(for: .milliseconds(180))
                checks["popup_stays_open_while_draft_has_content"] = sendPicker.isVisible
                draftContent = false
                try await Task.sleep(for: .milliseconds(450))
                checks["draft_clear_dismisses_native_popup_without_sending"] = !sendPicker.isVisible && session.plan == nil
                // Restore the inert search plan for the remaining search checks.
                session.receive(plan)
                for _ in 0..<80 where session.searching { try await Task.sleep(for: .milliseconds(50)) }
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
            result["passed"] = checks.count == 17 && checks.values.allSatisfy { $0 }
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            exit(result["passed"] as? Bool == true ? 0 : 1)
        }
        app.run()
    }
}
