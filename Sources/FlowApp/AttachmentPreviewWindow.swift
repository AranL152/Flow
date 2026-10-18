import AppKit
import SwiftUI
import Flow

@MainActor
final class AttachmentPreviewWindow {
    private let panel: NSPanel
    init(session: AttachmentSession, engine: Flow) {
        panel = NSPanel(contentViewController: NSHostingController(rootView:
            ScrollView { AttachmentCard(session: session, engine: engine).padding(12) }.background(FW.background)))
        panel.styleMask = [.titled, .closable, .nonactivatingPanel]
        panel.title = "Flow · Attachment"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(candidateCount: Int, isSearch: Bool = false) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let height = min(screen.height - 60, isSearch ? 720 : CGFloat(260 + max(1, candidateCount) * 72))
        panel.setContentSize(NSSize(width: 460, height: height))
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 480, y: screen.minY + 30))
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
