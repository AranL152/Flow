import AppKit
import Combine
import SwiftUI
import Flow

@MainActor
final class AttachmentPreviewWindow {
    private let panel: NSPanel
    private var host: NSHostingController<AnyView>!
    private var sessionChanges: AnyCancellable?
    private var resizeScheduled = false

    init(session: AttachmentSession, engine: Flow) {
        panel = AttachmentPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingController(rootView: AnyView(
            AttachmentCard(session: session, engine: engine, onLayoutChange: { [weak self] in self?.scheduleResize() })
                .frame(width: 360).fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        ))
        // Measure explicitly: automatic hosting constraints can recurse when a
        // borderless panel resizes during SwiftUI's own layout pass.
        host.sizingOptions = []
        panel.contentView = host.view
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.scheduleResize()
        }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.title = "Flow · Attachment"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Fit changes in results, errors, or the optional search field without a
        // second scroll container or a fixed, mostly empty window.
        panel.contentMinSize = NSSize(width: 360, height: 120)
        panel.contentMaxSize = NSSize(width: 360, height: 500)
    }
    func show(candidateCount: Int, isSearch: Bool = false) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        resizeToFit()
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 380, y: screen.minY + 30))
        panel.orderFrontRegardless()
    }
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Published values and SwiftUI state must settle before measuring.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeToFit()
        }
    }

    private func resizeToFit() {
        let availableHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let fitted = host.sizeThatFits(in: CGSize(width: 360, height: 10_000))
        let height = min(500, availableHeight - 60, max(120, ceil(fitted.height)))
        guard abs(contentSize.height - height) > 0.5 else { return }
        // Keep the popup's lower edge still as hints or search controls appear.
        let bottom = panel.frame.minY
        panel.setContentSize(NSSize(width: 360, height: height))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: bottom))
    }

    var contentSize: NSSize { panel.contentView?.frame.size ?? .zero }
    func hide() { panel.orderOut(nil) }
}

private final class AttachmentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
