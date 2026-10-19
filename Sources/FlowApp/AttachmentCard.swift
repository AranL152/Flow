import AppKit
import Flow
import SwiftUI
import QuickLookThumbnailing

/// A small picker beside the composer; larger previews are available on demand.
struct AttachmentCard: View {
    @ObservedObject var session: AttachmentSession
    let engine: Flow
    var onLayoutChange: () -> Void = {}
    @State private var previewID: UUID?
    @State private var showSearch = false

    private var showingAlternatives: Bool {
        session.attachedID != nil && (session.attachmentConfirmed || session.busy) &&
            session.candidates.contains { $0.id != session.attachedID }
    }

    private var visibleCandidates: [AttachmentCandidate] {
        showingAlternatives ? session.candidates.filter { $0.id != session.attachedID } : session.candidates
    }

    private var footerHint: String {
        if showingAlternatives && session.selectedID == session.attachedID { return "Select one to replace" }
        if session.attachedID != nil && session.selectedID != session.attachedID { return "Replaces Flow’s file only" }
        return "You review and send"
    }

    var body: some View {
        if let plan = session.plan {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").foregroundStyle(FW.accent)
                    Text("Flow attach").font(.system(size: 13, weight: .semibold))
                    FlowCommandBadge(title: "Command")
                    Spacer()
                    if session.searching || session.busy { ProgressView().controlSize(.mini) }
                    Menu {
                        if plan.request?.source == .fileSearch {
                            Button("Refine search…") { showSearch.toggle() }
                                .disabled(session.pasteRequested)
                            Button("Choose another file…") { session.chooseFile() }
                                .disabled(session.pasteRequested)
                        } else {
                            Button("Refresh source") { session.refresh() }.disabled(session.pasteRequested)
                        }
                        Button("Copy selected file") { session.copySelected() }.disabled(session.selected == nil)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(session.busy)
                    .help("Attachment options")
                    Button { session.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(FW.textMuted).disabled(session.busy)
                        .help("Dismiss attachments")
                }
                if showSearch, plan.request?.source == .fileSearch {
                    HStack(spacing: 6) {
                        TextField(plan.request?.kind == .image ? "Filename or screenshot text" : "Filename or document text", text: $session.searchText)
                            .textFieldStyle(.roundedBorder).onSubmit { session.searchFiles() }
                        Button { session.searchFiles() } label: { Image(systemName: "magnifyingglass") }
                            .help(plan.request?.kind == .image ? "Search filenames and visible text in recent screenshots locally" : "Search filenames and PDF or slide text locally")
                    }.disabled(session.busy || session.pasteRequested)
                }
                HStack {
                    Text(showingAlternatives ? "Other matches" : session.attachmentConfirmed ? "Added to your draft" : session.searching ? "Finding files…" : "Choose an attachment")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(FW.textSecondary)
                    Spacer()
                    if !visibleCandidates.isEmpty {
                        Text("\(visibleCandidates.count) \(visibleCandidates.count == 1 ? "match" : "matches")")
                            .font(.system(size: 10)).foregroundStyle(FW.textMuted)
                    }
                }
                if !visibleCandidates.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleCandidates) { candidate in row(candidate) }
                        }
                    }
                    .frame(height: CGFloat(min(visibleCandidates.count, 3)) * 58 - 4)
                    .focusable().focusEffectDisabled()
                    .onMoveCommand { direction in
                        guard !session.busy, !visibleCandidates.isEmpty, direction == .up || direction == .down else { return }
                        let current = visibleCandidates.firstIndex { $0.id == session.selectedID } ?? -1
                        let next = min(visibleCandidates.count - 1, max(0, current + (direction == .down ? 1 : -1)))
                        session.choose(visibleCandidates[next].id)
                    }
                }
                // Keep errors visible, while successful state is communicated in the row.
                if session.selected == nil || session.busy || (!session.attachmentConfirmed && session.pasteRequested) || session.hasIssue {
                    Text(session.status).font(.system(size: 11)).foregroundStyle(FW.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Text(footerHint)
                        .font(.system(size: 10)).foregroundStyle(FW.textMuted)
                    Spacer(minLength: 2)
                    Button(actionTitle) {
                        if needsManualCopy { session.copySelected() }
                        else if session.selectedID == session.attachedID { session.revealTarget(); session.dismiss() }
                        else { Task { await session.stage(engine: engine) } }
                    }
                    .buttonStyle(FWSecondaryButtonStyle())
                    .disabled(session.selected == nil || session.busy)
                }
            }
            .padding(14).background(FW.background).foregroundStyle(FW.textPrimary)
            .accessibilityIdentifier("attachment-preview")
            .onChange(of: showSearch) { _, _ in onLayoutChange() }
            .onExitCommand { if !session.busy { session.dismiss() } }
        }
    }

    private var needsManualCopy: Bool { session.pasteRequested && !session.attachmentConfirmed }

    private var actionTitle: String {
        if needsManualCopy { return "Copy file" }
        if session.selectedID == session.attachedID, session.attachedID != nil { return "Done" }
        return session.attachedID == nil ? "Add file" : "Replace"
    }

    private func row(_ candidate: AttachmentCandidate) -> some View {
        let selected = session.selectedID == candidate.id
        let attached = session.attachmentConfirmed && session.attachedID == candidate.id
        return HStack(spacing: 0) {
            Button { session.choose(candidate.id) } label: {
                HStack(spacing: 9) {
                    AttachmentThumbnail(candidate: candidate).frame(width: 34, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.filename).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(candidate.matchDescription ?? (attached ? "In draft" : candidate.approximateRecency ? "Confirm this file" : session.plan?.request?.source == .fileSearch && session.candidates.first?.id == candidate.id ? "Best filename match" : candidate.sourceLabel))
                            .font(.system(size: 10)).foregroundStyle(attached ? FW.accent : FW.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(selected ? FW.accent : FW.border)
                }
                .contentShape(Rectangle()).padding(.leading, 9).padding(.vertical, 8)
            }.buttonStyle(.plain).disabled(session.busy)
                .accessibilityLabel("\(candidate.filename)\(attached ? ", in draft" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button { previewID = candidate.id } label: {
                Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(FW.textSecondary)
                    .frame(width: 32, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Preview \(candidate.filename)")
                .popover(isPresented: Binding(get: { previewID == candidate.id }, set: { if !$0 { previewID = nil } }), arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: 10) {
                        AttachmentThumbnail(candidate: candidate, previewSize: 720).frame(width: 300, height: 230)
                        Text(candidate.filename).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        if let reason = candidate.matchDescription {
                            Text(reason).font(.caption).foregroundStyle(FW.accent)
                        }
                        Text(candidate.sourceLabel).font(.caption).foregroundStyle(FW.textMuted)
                    }.padding(14).background(FW.background)
                }
        }
        .frame(height: 54)
        .background(selected ? FW.accent.opacity(0.08) : FW.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? FW.accent.opacity(0.35) : FW.border.opacity(0.65), lineWidth: 1))
    }
}

private struct AttachmentThumbnail: View {
    let candidate: AttachmentCandidate
    var previewSize: CGFloat = 104
    @State private var thumbnail: NSImage?
    var body: some View {
        Image(nsImage: thumbnail ?? fallback).resizable().scaledToFit()
            .task(id: candidate.id) {
                guard let url = candidate.fileURL else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: previewSize, height: previewSize), scale: 2, representationTypes: .thumbnail)
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
