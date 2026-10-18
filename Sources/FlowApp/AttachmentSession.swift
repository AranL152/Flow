import AppKit
import ApplicationServices
import Flow
import UniformTypeIdentifiers

/// Captured independently of the text writer: an attachment-only command must
/// leave existing text and selection untouched.
@MainActor
private final class AttachmentPasteTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let contact: String

    init?(app: NSRunningApplication?, contact: String?) {
        guard AXIsProcessTrusted(), let app, app.bundleIdentifier == "com.apple.MobileSMS",
              let contact, !contact.isEmpty,
              let element = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier) else { return nil }
        guard AXEditMonitorService.isMessagesComposer(element) else { return nil }
        self.app = app; self.element = element; self.contact = contact
    }

    func matches(engine: Flow) -> Bool {
        guard !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              engine.activeMessagesContact?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == contact.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let current = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier) else { return false }
        return CFEqual(current, element)
    }
}

@MainActor
final class AttachmentSession: ObservableObject {
    @Published private(set) var plan: AttachmentPlan?
    @Published private(set) var candidates: [AttachmentCandidate] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var pasteRequested = false
    @Published private(set) var attachmentConfirmed = false
    @Published private(set) var needsChoice = false
    @Published private(set) var attachedID: UUID?
    @Published var searchText = ""
    @Published private(set) var searching = false
    private var clipboard: AttachmentClipboardSnapshot?
    private var clipboardChanged = false
    private let downloads: AttachmentDownloads
    private var timer: Timer?
    private var target: AttachmentPasteTarget?
    private var sessionID = UUID()
    private let fileSearch = AttachmentFileSearch()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    var onDismiss: (() -> Void)?

    var selected: AttachmentCandidate? { candidates.first { $0.id == selectedID } }
    var recipient: String? { target?.contact }

    init(downloads: AttachmentDownloads = AttachmentDownloads()) { self.downloads = downloads }

    @discardableResult
    func startObservingDownloads() -> Bool {
        guard timer == nil else { return true }
        do { try downloads.observe() }
        catch { status = error.localizedDescription; return false }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do { try self.downloads.observe() }
                catch { self.stopObservingDownloads() }
            }
        }
        return true
    }

    func stopObservingDownloads() { timer?.invalidate(); timer = nil }

    func targetMatches(engine: Flow) -> Bool { target?.matches(engine: engine) == true }

    func revealTarget() { target?.app.activate(options: [.activateAllWindows]) }

    func begin(app: NSRunningApplication?, contact: String?, board: NSPasteboard = .general) {
        dismiss()
        clipboard = AttachmentClipboardSnapshot(board: board)
        target = AttachmentPasteTarget(app: app, contact: contact)
    }

    func receive(_ plan: AttachmentPlan, board: NSPasteboard = .general) {
        self.plan = plan
        searchText = plan.request?.query ?? ""
        clipboardChanged = clipboard.map { $0.changeCount != board.changeCount } ?? false
        if plan.request?.source == .recentDownload && timer == nil {
            // Access Downloads only after an explicit voice command. Never
            // trigger file-access dialogs during app launch or ordinary speech.
            guard startObservingDownloads() else { return }
            let session = sessionID
            status = "Checking the newest matching download…"
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1100))
                guard let self, self.sessionID == session, !Task.isCancelled else { return }
                self.resolve()
            }
        } else { resolve() }
    }

    func refresh() {
        guard !busy else { return }
        if plan?.request?.source == .clipboard {
            clipboard = AttachmentClipboardSnapshot()
            clipboardChanged = false
        }
        resolve()
    }

    private func resolve() {
        candidates = []; selectedID = nil; needsChoice = false; pasteRequested = false; attachmentConfirmed = false; attachedID = nil
        guard let plan else { return }
        if let clarification = plan.clarification { status = clarification; return }
        guard let request = plan.request else { return }
        do {
            switch request.source {
            case .clipboard:
                guard let clipboard else { throw AttachmentFailure.unavailable("Copy an image or file, then refresh.") }
                candidates = [try clipboard.resolve(kind: request.kind)]
            case .recentDownload:
                candidates = try downloads.candidates(kind: request.kind)
            case .fileSearch:
                searchFiles()
                return
            }
            needsChoice = candidates.count > 1 || candidates.first?.approximateRecency == true
            if !needsChoice { selectedID = candidates.first?.id }
            if clipboardChanged && request.source == .clipboard {
                status = "Clipboard changed since recording. This preview is the original; refresh to use the current clipboard."
            } else if needsChoice {
                status = "Choose the file to attach. Download order before Flow started is approximate."
            } else { status = "Ready to add\(recipient.map { " to \($0)" } ?? ""). You send the message." }
        } catch { status = error.localizedDescription }
    }

    func choose(_ id: UUID) {
        guard !busy, candidates.contains(where: { $0.id == id }) else { return }
        selectedID = id; needsChoice = false
        status = id == attachedID ? "Already in your Messages draft. You send the message."
            : attachedID == nil ? "Selected for review. You send the message." : "Previewing an alternative. Copy it if you want to change the attachment."
    }

    func automaticallyStage(engine: Flow, insertionUnchanged: Bool) async {
        guard insertionUnchanged, target?.matches(engine: engine) == true else { return }
        let session = sessionID, search = searchGeneration
        if plan?.request?.source == .fileSearch {
            await searchTask?.value
            guard sessionID == session, searchGeneration == search, !Task.isCancelled,
                  searchText == plan?.request?.query, target?.matches(engine: engine) == true else { return }
            if selectedID == nil, let best = candidates.first { choose(best.id) }
        }
        guard plan?.request?.source != .clipboard || !clipboardChanged,
              let selected, !selected.approximateRecency else { return }
        await stage(engine: engine, activate: false)
    }

    func stage(engine: Flow, activate: Bool = true) async {
        guard !busy, !pasteRequested, let candidate = selected else { return }
        guard let target else {
            status = "Automatic attachment insertion needs a captured Messages composer and contact. Copy the attachment and paste it into your draft."
            return
        }
        busy = true
        let session = sessionID
        defer { if sessionID == session { busy = false } }
        if activate {
            target.app.activate(options: [.activateAllWindows])
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard sessionID == session, !Task.isCancelled, target.matches(engine: engine) else {
            status = "The contact or composer changed. Attachment kept here; nothing was pasted."
            return
        }
        do {
            try candidate.validate()
            let before = AXEditMonitorService.attachmentCount(in: target.element)
            let board = NSPasteboard.general
            let previous = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            try candidate.write(to: board)
            let writtenCount = board.changeCount
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
                restore(previous, board: board, expectedCount: writtenCount)
                throw AttachmentFailure.unavailable("Couldn't create the attachment paste event.")
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
            pasteRequested = true
            attachedID = candidate.id
            status = "Paste requested in \(target.contact)’s Messages draft. Review the attachment, then send."
            // Restore only our own write. A later copy by the user always wins.
            try? await Task.sleep(for: .milliseconds(600))
            restore(previous, board: board, expectedCount: writtenCount)
            if sessionID == session, let before,
               let after = AXEditMonitorService.attachmentCount(in: target.element), after > before {
                attachmentConfirmed = true
                status = "Attachment added to \(target.contact)’s Messages draft. Review, then send."
            }
        } catch { status = error.localizedDescription }
    }

    private func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]], board: NSPasteboard, expectedCount: Int) {
        guard board.changeCount == expectedCount else { return }
        board.clearContents()
        let copies = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !copies.isEmpty { board.writeObjects(copies) }
    }

    func copySelected() {
        guard let selected else { return }
        do { try selected.write(to: .general); status = "Attachment copied. Paste it into your draft; you send the message." }
        catch { status = error.localizedDescription }
    }

    func searchFiles() {
        guard !busy, !pasteRequested, let request = plan?.request, request.source == .fileSearch else { return }
        searchTask?.cancel(); fileSearch.cancel()
        searchGeneration = UUID()
        candidates = []; selectedID = nil; needsChoice = true; searching = true
        status = "Searching filenames on this Mac…"
        let session = sessionID
        let text = searchText
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.fileSearch.search(text, kind: request.kind)
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.candidates = found
                self.status = found.isEmpty
                    ? "No matching filenames in Spotlight. Try fewer words or choose a file manually."
                    : "Choose a file to preview, then Add to Messages. Nothing is attached automatically."
            } catch {
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.status = error.localizedDescription
            }
            self.searching = false
        }
    }

    func chooseFile() {
        guard !busy, !pasteRequested else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Preview attachment"
        switch plan?.request?.kind {
        case .image: panel.allowedContentTypes = [.image]
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .presentation: panel.allowedContentTypes = [.presentation] + [UTType(filenameExtension: "key")].compactMap { $0 }
        default: break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        searchTask?.cancel(); fileSearch.cancel(); searching = false
        do {
            let candidate = try AttachmentCandidate(fileURL: url, sourceLabel: "Chosen file")
            candidates = [candidate]; choose(candidate.id)
        } catch { status = error.localizedDescription }
    }

    func dismiss() {
        searchTask?.cancel(); searchTask = nil; fileSearch.cancel(); searching = false; searchText = ""
        sessionID = UUID(); plan = nil; candidates = []; selectedID = nil
        clipboard = nil; target = nil; clipboardChanged = false
        needsChoice = false; status = ""; busy = false; pasteRequested = false; attachmentConfirmed = false
        attachedID = nil
        onDismiss?()
    }
}
