import Flow
import SwiftUI

struct FlowCommandCaptionView: View {
    let transcript: String
    let status: String
    let isRecording: Bool
    @ObservedObject var attachments: AttachmentSession
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.flowReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var rippleStart: Date?
    @State private var rippleActive = false
    @State private var played = false

    private var parts: FlowCommandCaption? { FlowCommandCaption.detect(in: transcript, isRecording: isRecording) }
    private var commandStatus: String {
        guard let plan = attachments.plan else { return "Flow command" }
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
        return "Flow command"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text(isRecording ? "YOU’RE SAYING" : "YOU SAID")
                if parts != nil { FlowCommandBadge(title: commandStatus, onDarkSurface: true) }
                Spacer(minLength: 2)
                if isRecording { Text("LIVE").foregroundStyle(FW.recording) }
            }
            .font(.system(size: 9, weight: .semibold)).tracking(1)
            .foregroundStyle(.white.opacity(0.5))
            Group {
                if let parts {
                    VStack(alignment: .leading, spacing: 2) {
                        if !parts.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(String(parts.message.trimmingCharacters(in: .whitespacesAndNewlines).suffix(100)))
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1).truncationMode(.head)
                        }
                        LiquidCommandText(command: displayCommand(parts.command), width: FlowCaptionMetrics.textWidth, rippleStart: rippleStart, animating: rippleActive)
                    }
                } else {
                    Text(transcript.isEmpty ? status : String(transcript.suffix(160)))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(transcript.isEmpty ? 0.5 : 0.95))
                        .lineLimit(2).contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .accessibilityIdentifier("recording-live-transcript")
        }
        .padding(.horizontal, FlowCaptionMetrics.inset).padding(.vertical, 12)
        .frame(width: FlowCaptionMetrics.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .onAppear { startRippleIfReady() }
        .onChange(of: isRecording) { _, recording in
            if recording { played = false; rippleActive = false; rippleStart = nil }
            else { startRippleIfReady() }
        }
        .onChange(of: parts != nil) { _, detected in
            if !detected { rippleActive = false; rippleStart = nil }
            else { startRippleIfReady() }
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { rippleActive = false } }
        .task(id: rippleStart) {
            guard let started = rippleStart else { return }
            do { try await Task.sleep(for: .seconds(LiquidCommandText.animationDuration)) } catch { return }
            guard !Task.isCancelled, started == rippleStart else { return }
            rippleActive = false
        }
    }

    private func startRippleIfReady() {
        guard !isRecording, parts != nil, !played else { return }
        played = true
        guard !reduceMotion else { return }
        rippleStart = Date(); rippleActive = true
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
