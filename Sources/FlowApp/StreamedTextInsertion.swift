import AppKit
import ApplicationServices
import Flow

/// Writes only the captured composer range. Never types Return or touches the
/// clipboard. User input, focus changes, and unexpected field edits stop writes.
@MainActor
final class StreamedTextInsertion {
    private enum Mode { case value, selection }
    private let element: AXUIElement
    private let pid: pid_t
    private let mode: Mode
    private var buffer: StreamInsertionBuffer
    private var monitor: Any?
    private var ended = false
    private(set) var interrupted = false
    private(set) var writeCount = 0
    var onInterrupted: (() -> Void)?

    static func capture(app: NSRunningApplication?, ignoredKeyCode: UInt16? = nil) -> StreamedTextInsertion? {
        guard AXIsProcessTrusted(), let app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let element = AXEditMonitorService.getFocusedTextElement(pid: app.processIdentifier),
              let text = value(of: element), let selection = selection(of: element),
              settable(kAXSelectedTextRangeAttribute, on: element),
              let buffer = try? StreamInsertionBuffer(original: text, selection: selection) else { return nil }
        let mode: Mode
        if settable(kAXValueAttribute, on: element) { mode = .value }
        else if settable(kAXSelectedTextAttribute, on: element) { mode = .selection }
        else { return nil }
        let insertion = StreamedTextInsertion(element: element, pid: app.processIdentifier, mode: mode, buffer: buffer)
        insertion.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak insertion] event in
            if event.type == .keyDown, event.keyCode == ignoredKeyCode { return }
            Task { @MainActor in insertion?.interrupt() }
        }
        return insertion
    }

    private init(element: AXUIElement, pid: pid_t, mode: Mode, buffer: StreamInsertionBuffer) {
        self.element = element; self.pid = pid; self.mode = mode; self.buffer = buffer
    }

    @discardableResult
    func apply(output: String) -> Bool {
        guard !ended, !interrupted, ownsFocus(), let text = Self.value(of: element),
              let selection = Self.selection(of: element),
              let update = try? buffer.propose(output: output, observedText: text, observedSelection: selection) else {
            interrupt(); return false
        }
        if update.text == text { return true }
        guard write(text: update.text, replacement: output, range: update.replacementRange, selection: update.selection),
              Self.value(of: element) == update.text, Self.selection(of: element) == update.selection else {
            interrupt(); return false
        }
        buffer.acknowledge(update); writeCount += 1
        return true
    }

    func finish(output: String) -> Bool {
        let success = apply(output: output)
        end()
        return success
    }

    /// Roll back only when the field is still exactly the draft we wrote.
    @discardableResult
    func cancel(restoringOriginal: Bool) -> Bool {
        var restored = false
        if restoringOriginal, !interrupted, writeCount > 0, ownsFocus(),
           let text = Self.value(of: element), let selection = Self.selection(of: element),
           buffer.canRestore(observedText: text, observedSelection: selection) {
            let selected = (buffer.original as NSString).substring(with: buffer.originalSelection)
            restored = write(text: buffer.original, replacement: selected, range: buffer.insertionRange, selection: buffer.originalSelection)
        }
        end()
        return restored
    }

    private func interrupt() {
        guard !ended, !interrupted else { return }
        interrupted = true; end(); onInterrupted?()
    }

    private func end() {
        ended = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func ownsFocus() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AXEditMonitorService.getFocusedTextElement(pid: pid) else { return false }
        return CFEqual(focused, element)
    }

    private func write(text: String, replacement: String, range: NSRange, selection: NSRange) -> Bool {
        let result: AXError
        switch mode {
        case .value:
            result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        case .selection:
            guard setSelection(range) else { return false }
            result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString)
        }
        return result == .success && setSelection(selection)
    }

    private func setSelection(_ range: NSRange) -> Bool {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selection(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func settable(_ attribute: String, on element: AXUIElement) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }
}
