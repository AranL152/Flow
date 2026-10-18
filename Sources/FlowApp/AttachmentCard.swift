import AppKit
import Flow
import SwiftUI
import QuickLookThumbnailing

struct AttachmentCard: View {
    @ObservedObject var session: AttachmentSession
    let engine: Flow

    var body: some View {
        if let plan = session.plan {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Flow, attach", systemImage: "paperclip").font(.headline)
                    Spacer()
                    Button { session.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(session.busy).help("Dismiss attachment preview")
                }
                Text(plan.command).font(.caption).foregroundStyle(FW.textMuted).textSelection(.enabled)
                ForEach(session.candidates) { candidate in
                    Button { session.choose(candidate.id) } label: {
                        HStack(spacing: 12) {
                            AttachmentThumbnail(candidate: candidate).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.filename).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text(candidate.sourceLabel + (candidate.approximateRecency ? " · choose to confirm" : ""))
                                    .font(.caption).foregroundStyle(FW.textMuted)
                            }
                            Spacer()
                            if session.selectedID == candidate.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(FW.accent) }
                        }
                        .padding(10)
                        .background(session.selectedID == candidate.id ? FW.accent.opacity(0.1) : FW.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(session.busy || session.pasteRequested)
                }
                Text(session.status).font(.caption).foregroundStyle(FW.textSecondary)
                HStack {
                    Button("Refresh source") { session.refresh() }.disabled(session.busy || plan.request == nil)
                    Spacer()
                    Button("Copy attachment") { session.copySelected() }.disabled(session.selected == nil || session.busy)
                    Button(session.pasteRequested ? "Review in Messages" : "Add to Messages") {
                        if session.pasteRequested { session.revealTarget() }
                        else { Task { await session.stage(engine: engine) } }
                    }.disabled(session.selected == nil || session.busy)
                }.buttonStyle(FWSecondaryButtonStyle())
            }
            .padding(16).fwSection()
            .accessibilityIdentifier("attachment-preview")
        }
    }

}

private struct AttachmentThumbnail: View {
    let candidate: AttachmentCandidate
    @State private var thumbnail: NSImage?
    var body: some View {
        Image(nsImage: thumbnail ?? fallback).resizable().scaledToFit()
            .task(id: candidate.id) {
                guard let url = candidate.fileURL else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 104, height: 104), scale: 2, representationTypes: .thumbnail)
                if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    thumbnail = representation.nsImage
                }
            }
    }
    private var fallback: NSImage {
        if let data = candidate.imageData, let image = NSImage(data: data) { return image }
        if let url = candidate.fileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    }
}
