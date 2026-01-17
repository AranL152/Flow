//
// RecordingIndicatorWindow.swift
// FlowWispr
//
// Lightweight, non-activating recording indicator shown when the app is not frontmost.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorWindow {
    private let window: NSPanel

    init(appState: AppState) {
        let view = RecordingIndicatorView()
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 220, height: 44), display: false)

        self.window = panel
        positionWindow()
    }

    func show() {
        positionWindow()
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = window.frame.size
        let padding: CGFloat = 16
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - padding
        )
        window.setFrameOrigin(origin)
    }
}

private struct RecordingIndicatorView: View {
    @EnvironmentObject var appState: AppState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: FW.spacing8) {
            Circle()
                .fill(FW.recording)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.5 : 1.0)

            Text("Recording")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Text(formatDuration(appState.recordingDuration))
                .font(FW.fontMonoSmall)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, FW.spacing12)
        .padding(.vertical, FW.spacing6)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.7))
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func formatDuration(_ ms: UInt64) -> String {
        let seconds = ms / 1000
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
