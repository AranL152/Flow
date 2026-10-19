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
    private var wantsVisible = false

    init(appState: AppState, attachments: AttachmentSession? = nil) {
        let view = RecordingIndicatorView(attachmentSession: attachments)
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Flow · Recording"
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 500, height: 190), display: false)

        window = panel
        positionWindow()
    }

    func show() {
        // Recording/loading/processing can each request the same visible panel.
        // Do not restart its fade or move it on those phase updates.
        guard !wantsVisible else { return }
        wantsVisible = true
        visibility = UUID()
        let session = visibility
        if !window.isVisible { window.alphaValue = 0 }
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
        guard wantsVisible else { return }
        wantsVisible = false
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
    var attachmentSession: AttachmentSession? = nil
    private var processing: Bool { appState.isProcessing || (!appState.isRecording && appState.captionPresentationActive) }
    var body: some View {
        VStack(spacing: 10) {
            if appState.liveCaptionsEnabled && !appState.isInitializingModel {
                FlowCommandCaptionView(transcript: appState.liveTranscript, status: appState.liveCaptionStatus,
                                       isRecording: appState.isRecording, isTranscriptFinal: appState.liveTranscriptFinalized,
                                       attachments: attachmentSession ?? appState.attachments,
                                       onPresentationState: { appState.captionPresentationActive = $0 })
            }
            HStack(spacing: 10) {
                if processing || appState.isInitializingModel {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .environment(\.colorScheme, .dark)
                        .frame(width: 14, height: 14)
                } else if appState.isRecording {
                    Circle().fill(FW.recording).frame(width: 7, height: 7)
                }
                if appState.isRecording && !appState.isProcessing && !appState.isInitializingModel {
                    CompactWaveformView(isRecording: true, audioLevel: appState.smoothedAudioLevel)
                }
                if !appState.isRecording || appState.isProcessing || appState.isInitializingModel {
                    Text(appState.isInitializingModel ? "Loading model…" : "Transcribing…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if appState.isRecording && !appState.isProcessing && !appState.isInitializingModel {
                    Text(String(format: "%d:%02d", appState.recordingDuration / 60000, appState.recordingDuration / 1000 % 60))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                } else if processing || appState.isInitializingModel {
                    // Balance the spinner's width so the label itself is centered.
                    Color.clear.frame(width: 14, height: 14).accessibilityHidden(true)
                }
            }
            .frame(height: 20)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.9)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .compositingGroup()
    }
}
