import AppKit
import SwiftUI
import Flow

@MainActor
final class AttachmentPreviewWindow {
    private let panel: NSPanel
    private let measuredSize = AttachmentPanelMeasurement()
    init(session: AttachmentSession, engine: Flow) {
        panel = AttachmentPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let measuredSize = self.measuredSize
        let host = NSHostingView(rootView: AttachmentCard(session: session, engine: engine)
            .frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .background(GeometryReader { proxy in Color.clear.preference(key: AttachmentPanelSize.self, value: proxy.size) })
            .onPreferenceChange(AttachmentPanelSize.self) { [weak panel] size in
                guard size.height > 0 else { return }
                measuredSize.height = size.height
                // Resize outside SwiftUI's constraint pass to avoid recursive
                // AppKit/hosting-view layout on changing candidate counts.
                DispatchQueue.main.async { [weak panel] in
                    guard let panel else { return }
                    let height = min(500, max(120, measuredSize.height ?? size.height))
                    if abs((panel.contentView?.frame.height ?? 0) - height) > 0.5 {
                        panel.setContentSize(NSSize(width: 360, height: height))
                    }
                }
            })
        host.sizingOptions = []
        panel.contentView = host
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
        let height = measuredSize.height ?? CGFloat(130 + min(3, candidateCount) * 58)
        panel.setContentSize(NSSize(width: 360, height: min(screen.height - 60, height)))
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 380, y: screen.minY + 30))
        panel.orderFrontRegardless()
    }
    var contentSize: NSSize { panel.contentView?.frame.size ?? .zero }
    func hide() { panel.orderOut(nil) }
}

private struct AttachmentPanelSize: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private final class AttachmentPanelMeasurement {
    var height: CGFloat?
}

private final class AttachmentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
