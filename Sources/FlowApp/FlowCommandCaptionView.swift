import Flow
import SwiftUI

struct FlowCommandCaptionView: View {
    let transcript: String
    let status: String
    let isRecording: Bool
    var isTranscriptFinal = false
    @ObservedObject var attachments: AttachmentSession
    var onPresentationState: ((Bool) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.flowReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var rippleStart: Date?
    @State private var rippleActive = false
    @State private var reveal = CaptionTextReveal()
    @State private var recognized = false

    static let whiteCaptionHold: TimeInterval = 0.22
    private struct Input: Equatable {
        let text: String
        let recording: Bool
        let final: Bool
    }

    // The boundary may lay out in white while speaking, but never activates an
    // effect until the entire finalized caption has actually been displayed.
    private var parts: FlowCommandCaption? {
        guard FlowCommandCaption.detect(in: transcript) != nil else { return nil }
        return FlowCommandCaption.detect(in: reveal.text)
    }
    private var commandStatus: String? {
        guard let plan = attachments.plan else { return nil }
        if plan.clarification != nil { return "Needs detail" }
        if attachments.attachmentConfirmed { return "Added to draft" }
        if attachments.busy { return "Adding attachment…" }
        if attachments.searching {
            if plan.request?.kind == .image {
                return plan.command.range(of: "screenshot", options: .caseInsensitive) != nil ? "Finding screenshot…" : "Finding image…"
            }
            return "Finding file…"
        }
        if !attachments.candidates.isEmpty { return "Attachment found" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                if isRecording {
                    ListeningStatusLabel()
                } else if recognized, let commandStatus {
                    Text(commandStatus)
                        .foregroundStyle(FlowCommandBadge.ink)
                        .accessibilityIdentifier("flow-command-status")
                } else {
                    Text("Transcribing…")
                }
                Spacer(minLength: 2)
                if isRecording { Text("LIVE").foregroundStyle(FW.recording) }
            }
            .font(.system(size: 9, weight: .semibold)).tracking(1)
            .foregroundStyle(.white.opacity(0.5))
            .frame(height: 14)
            Group {
                if let parts {
                    VStack(alignment: .leading, spacing: 2) {
                        if !parts.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(String(parts.message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(100)))
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1).truncationMode(.head)
                        }
                        LiquidCommandText(command: displayCommand(parts.command), width: FlowCaptionMetrics.textWidth, rippleStart: rippleStart, animating: rippleActive, recognized: recognized)
                    }
                } else {
                    Text(reveal.text.isEmpty ? status : reveal.text)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(reveal.text.isEmpty ? 0.5 : 0.95))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            .accessibilityIdentifier("recording-live-transcript")
        }
        .padding(.horizontal, FlowCaptionMetrics.inset).padding(.vertical, 12)
        .frame(width: FlowCaptionMetrics.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .task(id: Input(text: transcript, recording: isRecording, final: isTranscriptFinal)) { await presentCaption() }
        .onDisappear { onPresentationState?(false) }
        .onChange(of: reduceMotion) { _, reduced in if reduced { rippleActive = false } }
    }

    private func presentCaption() async {
        recognized = false; rippleActive = false; rippleStart = nil
        let finalCommand = !isRecording && isTranscriptFinal && FlowCommandCaption.detect(in: transcript) != nil
        onPresentationState?(finalCommand)
        let target: String
        if let full = FlowCommandCaption.detect(in: transcript) {
            target = String(full.message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(100))
                + (full.message.isEmpty ? "" : " ") + displayCommand(full.command)
        } else { target = String(transcript.suffix(160)) }
        reveal.retarget(target)
        do {
            while reveal.advance() {
                if !reduceMotion { try await Task.sleep(for: .milliseconds(18)) }
                try Task.checkCancellation()
            }
            guard finalCommand else { return }
            // A rendered, complete white caption precedes recognition, even if
            // the provider delivered its last words after recording stopped.
            try await Task.sleep(for: .seconds(Self.whiteCaptionHold))
            try Task.checkCancellation()
            recognized = true
            if !reduceMotion {
                rippleStart = Date(); rippleActive = true
                try await Task.sleep(for: .seconds(LiquidCommandText.animationDuration))
            }
            try Task.checkCancellation()
            rippleActive = false
            onPresentationState?(false)
        } catch { /* A new ASR revision owns the next presentation task. */ }
    }

    private func displayCommand(_ command: String) -> String {
        guard command.count > 160 else { return command }
        return String(command.prefix(32)) + "…" + String(command.suffix(120))
    }
}

enum FlowCaptionMetrics {
    static let width: CGFloat = 440
    static let inset: CGFloat = 16
    static let textWidth = width - 2 * inset
}
