//
// RecordingIndicatorWindow.swift
// Flow
//
// Lightweight, non-activating recording indicator shown while recording or processing.
//

import AppKit
import Flow
import SwiftUI

@MainActor
final class RecordingIndicatorWindow {
    private let window: NSPanel
    private var visibility = UUID()
    private var wantsVisible = false
    private var anchor: RecordingComposerAnchor?
    private var lastComposerFrame: CGRect?
    private var targetPrepared = false
    private var tracking: Timer?
    private var placementSide: DictationOverlayPlacement.Side?
    private let preferredSize = CGSize(width: 500, height: 190)

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

    /// A new recording can start while the previous command's caption is fading.
    /// Refresh the target once here; phase updates must keep the same anchor.
    func prepare(near application: NSRunningApplication?) {
        anchor = RecordingComposerAnchor(app: application)
        lastComposerFrame = anchor?.frame
        placementSide = nil
        targetPrepared = true
        if wantsVisible { positionWindow() }
    }

    func show(near application: NSRunningApplication? = nil) {
        // Recording/loading/processing can each request the same visible panel.
        // Do not restart its fade or move it on those phase updates.
        guard !wantsVisible else { return }
        wantsVisible = true
        if !targetPrepared { prepare(near: application ?? NSWorkspace.shared.frontmostApplication) }
        visibility = UUID()
        let session = visibility
        if !window.isVisible { window.alphaValue = 0 }
        positionWindow()
        window.orderFrontRegardless()
        tracking = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsVisible else { return }
                self.positionWindow()
            }
        }
        if let tracking { RunLoop.main.add(tracking, forMode: .common) }

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
        tracking?.invalidate(); tracking = nil
        anchor = nil; lastComposerFrame = nil; placementSide = nil; targetPrepared = false
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
        // Messages can briefly omit geometry while relaying out a growing draft.
        // Retain the last good frame instead of jumping back over the composer.
        if let frame = anchor?.frame { lastComposerFrame = frame }
        let screens = NSScreen.screens.sorted { a, b in a == NSScreen.main && b != NSScreen.main }.map(\.visibleFrame)
        let obstacles = NSApplication.shared.windows.filter { $0.isVisible && $0.title == "Flow · Attachment" }.map(\.frame)
        let placement = DictationOverlayPlacement.place(size: preferredSize, composer: lastComposerFrame,
            screens: screens, preferredSide: placementSide, avoiding: obstacles)
        placementSide = placement.side
        let current = window.frame, next = placement.frame
        guard abs(current.minX - next.minX) > 0.5 || abs(current.minY - next.minY) > 0.5 || current.size != next.size else { return }
        // No visibility/opacity animation on geometry updates: typing, processing
        // and a growing composer must not restart the panel's reveal animation.
        window.setFrame(next, display: true)
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
