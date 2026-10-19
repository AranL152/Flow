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
    @Published private(set) var hasIssue = false
    private var ownedAttachment: AXUIElement?
    private var clipboard: AttachmentClipboardSnapshot?
    private var clipboardChanged = false
    private let downloads: AttachmentDownloads
    private var timer: Timer?
    private var target: AttachmentPasteTarget?
    private var sessionID = UUID()
    private let fileSearch: AttachmentSearch
    private var searchTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    var onDismiss: (() -> Void)?

    var selected: AttachmentCandidate? { candidates.first { $0.id == selectedID } }
    /// Only native Messages confirmation can promote a candidate to "Added".
    var attached: AttachmentCandidate? {
        guard attachmentConfirmed else { return nil }
        return candidates.first { $0.id == attachedID }
    }
    var recipient: String? { target?.contact }

    init(downloads: AttachmentDownloads = AttachmentDownloads(), fileSearch: AttachmentSearch? = nil) {
        self.downloads = downloads; self.fileSearch = fileSearch ?? AttachmentSearch()
    }

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

    /// Read only the pinned conversation/composer. A send-button click can move
    /// focus away from the text field, so dismissal does not require text focus.
    func draftHasContent(engine: Flow) -> Bool? {
        guard !busy, let target, !target.app.isTerminated,
              let contact = engine.activeMessagesContact,
              contact.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == target.contact.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        // Messages may replace its AX composer after Send. Reacquire only a
        // genuine composer in the same conversation if the pinned one is stale.
        let snapshot: MessagesAttachmentSnapshot
        if let pinned = MessagesAttachmentSnapshot.read(target.element) { snapshot = pinned }
        else if let current = AXEditMonitorService.getFocusedTextElement(pid: target.app.processIdentifier),
                AXEditMonitorService.isMessagesComposer(current),
                let refreshed = MessagesAttachmentSnapshot.read(current) { snapshot = refreshed }
        else { return nil }
        return !snapshot.items.isEmpty || !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            resolutionTask = Task { [weak self] in
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
        candidates = []; selectedID = nil; needsChoice = false; pasteRequested = false; attachmentConfirmed = false; attachedID = nil; ownedAttachment = nil; hasIssue = false
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
        selectedID = id; needsChoice = false; hasIssue = false
        status = id == attachedID ? "Already in your Messages draft. You send the message."
            : attachedID == nil ? "Selected for review. You send the message." : "Choose Replace to change only the attachment Flow added."
    }

    func automaticallyStage(engine: Flow, insertionUnchanged: Bool) async {
        let session = sessionID, search = searchGeneration
        await resolutionTask?.value
        guard sessionID == session, !Task.isCancelled else { return }
        if plan?.request?.source == .fileSearch {
            await searchTask?.value
            guard sessionID == session, searchGeneration == search, !Task.isCancelled,
                  searchText == plan?.request?.query else { return }
        }
        guard plan?.request != nil else { return }
        guard insertionUnchanged, let target, target.matches(engine: engine) else {
            hasIssue = true
            status = self.target == nil
                ? "Click the Messages draft, then try the command again."
                : "The draft or recipient changed. Nothing was added."
            return
        }
        if plan?.request?.source == .fileSearch {
            if selectedID == nil, let best = candidates.first { choose(best.id) }
        }
        guard plan?.request?.source != .clipboard || !clipboardChanged,
              let selected, !selected.approximateRecency else { return }
        await stage(engine: engine, activate: false)
    }

    func stage(engine: Flow, activate: Bool = true) async {
        guard !busy, let candidate = selected, candidate.id != attachedID else { return }
        let replacing = pasteRequested
        hasIssue = false
        guard let target else {
            hasIssue = true
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
            hasIssue = true
            status = "The contact or composer changed. Attachment kept here; nothing was pasted."
            return
        }
        do {
            try candidate.validate()
            var selection: CFTypeRef?
            var range = CFRange()
            guard AXUIElementCopyAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
                  let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
                  AXValueGetValue(selection as! AXValue, .cfRange, &range), range.length == 0 else {
                throw AttachmentFailure.unavailable("Place the cursor without selecting existing text or attachments, then add the file.")
            }
            guard let before = MessagesAttachmentSnapshot.read(target.element) else {
                throw AttachmentFailure.unavailable("Cannot inspect this Messages draft. Your draft was kept.")
            }
            var replacementRange: CFRange?
            if replacing {
                guard let ownedAttachment, let item = before.items.first(where: { CFEqual($0.element, ownedAttachment) }) else {
                    throw AttachmentFailure.unavailable("Flow’s original file is no longer in this draft. Copy the selected file to add it manually.")
                }
                replacementRange = CFRange(location: item.range.location, length: item.range.length)
            }
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
            if var replacementRange {
                guard let value = AXValueCreate(.cfRange, &replacementRange),
                      AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                    restore(previous, board: board, expectedCount: writtenCount)
                    throw AttachmentFailure.unavailable("Messages could not select Flow’s file. Your draft was kept.")
                }
                var observed: CFTypeRef?
                var actual = CFRange()
                guard AXUIElementCopyAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, &observed) == .success,
                      let observed, CFGetTypeID(observed) == AXValueGetTypeID(),
                      AXValueGetValue(observed as! AXValue, .cfRange, &actual),
                      actual.location == replacementRange.location, actual.length == 1 else {
                    restore(previous, board: board, expectedCount: writtenCount)
                    throw AttachmentFailure.unavailable("Messages did not confirm the file selection. Nothing was pasted.")
                }
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
            pasteRequested = true
            attachmentConfirmed = false
            status = "Paste requested in \(target.contact)’s Messages draft. Review the attachment, then send."
            // Restore only our own write. A later copy by the user always wins.
            try? await Task.sleep(for: .milliseconds(600))
            restore(previous, board: board, expectedCount: writtenCount)
            guard sessionID == session else { return }
            guard var after = MessagesAttachmentSnapshot.read(target.element) else {
                throw AttachmentFailure.unavailable("Paste requested. Check the attachment in Messages.")
            }
            let added = after.added(comparedTo: before)
            let preserved = after.preservesObjects(in: before, excluding: replacing ? ownedAttachment : nil)
            if replacing, added.count == 1, preserved, after.items.count == before.items.count,
               let ownedAttachment, !after.contains(ownedAttachment),
               let old = before.items.first(where: { CFEqual($0.element, ownedAttachment) }), after.text != before.text {
                // Messages inserts a newline when pasting over a file object.
                // Remove only that exact newly inserted separator, after proving
                // every other character and native object is unchanged.
                let original = before.text as NSString
                var separator: CFRange?
                if after.text == original.replacingCharacters(in: old.range, with: "\n\u{FFFC}") {
                    separator = CFRange(location: old.range.location, length: 1)
                } else if after.text == original.replacingCharacters(in: old.range, with: "\u{FFFC}\n") {
                    separator = CFRange(location: old.range.location + 1, length: 1)
                }
                if var separator, target.matches(engine: engine),
                   MessagesAttachmentSnapshot.read(target.element)?.text == after.text,
                   let value = AXValueCreate(.cfRange, &separator),
                   AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                    var observed: CFTypeRef?
                    var actual = CFRange()
                    if AXUIElementCopyAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, &observed) == .success,
                       let observed, CFGetTypeID(observed) == AXValueGetTypeID(),
                       AXValueGetValue(observed as! AXValue, .cfRange, &actual), actual.location == separator.location, actual.length == 1,
                       let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: true),
                       let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: false) {
                        down.flags = []; up.flags = []
                        down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
                        for _ in 0..<20 {
                            try? await Task.sleep(for: .milliseconds(20))
                            guard sessionID == session, !Task.isCancelled else { return }
                            if let current = MessagesAttachmentSnapshot.read(target.element), current.text == before.text {
                                after = current; break
                            }
                        }
                    }
                }
            }
            guard added.count == 1, preserved,
                  after.items.count == before.items.count + (replacing ? 0 : 1), after.contains(added[0].element),
                  after.preservesObjects(in: before, excluding: replacing ? ownedAttachment : nil),
                  !replacing || (ownedAttachment.map { !after.contains($0) } == true && after.text == before.text) else {
                throw AttachmentFailure.unavailable("Messages did not confirm the attachment change. Review the draft before continuing.")
            }
            ownedAttachment = added[0].element
            attachedID = candidate.id
            attachmentConfirmed = true
            status = replacing ? "Attachment replaced. You send the message." : "Attachment added. You send the message."
        } catch { hasIssue = true; status = error.localizedDescription }
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
        catch { hasIssue = true; status = error.localizedDescription }
    }

    func searchFiles() {
        guard !busy, !pasteRequested, let request = plan?.request, request.source == .fileSearch else { return }
        searchTask?.cancel(); fileSearch.cancel()
        searchGeneration = UUID()
        candidates = []; selectedID = nil; needsChoice = true; searching = true; hasIssue = false
        status = request.kind == .image ? "Searching filenames and text in recent screenshots…" : "Searching filenames and document text…"
        let session = sessionID
        let text = searchText
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.fileSearch.search(text, kind: request.kind)
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.candidates = found
                self.status = found.isEmpty
                    ? (request.kind == .image ? "No matching filenames or recent screenshot text. Try words visible in the screenshot, or choose a file." : "No matching filenames or document text. Try fewer words or choose a file.")
                    : "Choose a file to preview or add to Messages."
            } catch {
                guard !Task.isCancelled, self.sessionID == session else { return }
                self.hasIssue = true; self.status = error.localizedDescription
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
        resolutionTask?.cancel(); resolutionTask = nil
        searchTask?.cancel(); searchTask = nil; fileSearch.cancel(); searching = false; searchText = ""
        sessionID = UUID(); plan = nil; candidates = []; selectedID = nil
        clipboard = nil; target = nil; clipboardChanged = false
        needsChoice = false; status = ""; busy = false; pasteRequested = false; attachmentConfirmed = false
        attachedID = nil; ownedAttachment = nil; hasIssue = false
        onDismiss?()
    }
}
