//
// RecordingIndicatorWindow.swift
// Flow
//
// Lightweight, non-activating recording indicator shown while recording or processing.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorWindow {
    private let window: NSPanel
    private var visibility = UUID()

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
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 500, height: 150), display: false)

        window = panel
        positionWindow()
    }

    func show() {
        visibility = UUID()
        let session = visibility
        window.alphaValue = 0
        positionWindow()
        window.orderFrontRegardless()

        // Small delay to ensure layout is settled before animating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.visibility == session else { return }
            // Reposition after layout settles to fix first-show centering
            self.positionWindow()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        visibility = UUID()
        let session = visibility
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0

            // Slide down slightly
            var frame = window.frame
            frame.origin.y -= 15
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visibility == session else { return }
                self.window.orderOut(nil)
                self.window.alphaValue = 1
                self.positionWindow() // Reset position for next show
            }
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = window.frame.size
        let padding: CGFloat = 12
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + padding
        )
        window.setFrameOrigin(origin)
    }
}

struct RecordingIndicatorView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(spacing: 10) {
            if appState.liveCaptionsEnabled && !appState.isInitializingModel {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text(appState.isRecording ? "YOU’RE SAYING" : "YOU SAID")
                        Spacer()
                        if appState.isRecording { Text("LIVE").foregroundStyle(FW.recording) }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
                    Text(appState.liveTranscript.isEmpty ? appState.liveCaptionStatus : String(appState.liveTranscript.suffix(160)))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(appState.liveTranscript.isEmpty ? 0.5 : 0.95))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("recording-live-transcript")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            HStack(spacing: 10) {
                if appState.isProcessing || appState.isInitializingModel {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else if appState.isRecording {
                    Circle().fill(FW.recording).frame(width: 7, height: 7)
                }
                if appState.isRecording && !appState.isProcessing && !appState.isInitializingModel {
                    CompactWaveformView(isRecording: true, audioLevel: appState.smoothedAudioLevel)
                }
                Text(appState.isInitializingModel ? "Loading model…" : (appState.isProcessing ? "Transcribing…" : "Listening"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if appState.isRecording && !appState.isProcessing && !appState.isInitializingModel {
                    Text(String(format: "%d:%02d", appState.recordingDuration / 60000, appState.recordingDuration / 1000 % 60))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.9)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .compositingGroup()
    }
}
