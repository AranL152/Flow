import AppKit
import ApplicationServices

/// Reads through the existing Accessibility grant. No Apple Events, System
/// Events automation, permission prompts, conversation history or recipient edits.
enum MessagesContext {
    static func currentContact() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let title = title as? String else { return nil }
        if let contact = normalizedContact(title) { return contact }
        // New-message drafts keep the generic window title after recipients
        // are committed. Read only header controls, never transcript/sidebar.
        var budget = 160
        return contactFromHeader(header(window as! AXUIElement, depth: 0, budget: &budget))
    }

    struct HeaderNode {
        var role = ""
        var identifier = ""
        var title = ""
        var description = ""
        var value = ""
        var children: [HeaderNode] = []
    }

    private static let excluded = Set(["ConversationList", "TranscriptCollectionView", "MessageEntryView", "messageBodyField"])

    private static func header(_ element: AXUIElement, depth: Int, budget: inout Int) -> HeaderNode {
        guard depth < 14, budget > 0 else { return HeaderNode() }
        budget -= 1
        func string(_ key: String) -> String {
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &raw)
            return raw as? String ?? ""
        }
        let role = string(kAXRoleAttribute), identifier = string(kAXIdentifierAttribute)
        guard !excluded.contains(identifier), !["AXScrollArea", "AXList", "AXOutline"].contains(role) else { return HeaderNode() }
        var raw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        let children = (raw as? [AXUIElement] ?? []).map { header($0, depth: depth + 1, budget: &budget) }
        return HeaderNode(role: role, identifier: identifier, title: string(kAXTitleAttribute),
                          description: string(kAXDescriptionAttribute), value: string(kAXValueAttribute), children: children)
    }

    static func contactFromHeader(_ root: HeaderNode) -> String? {
        func find(_ node: HeaderNode, matching predicate: (HeaderNode) -> Bool) -> HeaderNode? {
            guard !excluded.contains(node.identifier), !["AXScrollArea", "AXList", "AXOutline"].contains(node.role) else { return nil }
            if predicate(node) { return node }
            for child in node.children { if let found = find(child, matching: predicate) { return found } }
            return nil
        }
        if let recipients = find(root, matching: { $0.children.contains { $0.identifier == "To:" } }) {
            guard let address = recipients.children.first(where: { $0.identifier == "To:" }) else { return nil }
            let chips = recipients.children.filter { $0.role == "AXPopUpButton" }
            let recipients = chips.compactMap { chip -> (name: String, serialized: [String])? in
                var label = [chip.value, chip.title, chip.description].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                if label.hasSuffix(", Not registered") { label.removeLast(", Not registered".count) }
                guard let full = normalizedContact(label) else { return nil }
                // Saved contacts expose “Name, address” in the chip's accessible
                // description. Keep the display name for personalization; retain
                // the address only to validate the committed To-field serialization.
                if let comma = full.range(of: ", ", options: .backwards) {
                    let address = String(full[comma.upperBound...])
                    if isRecipientAddress(address), let name = normalizedContact(String(full[..<comma.lowerBound])) {
                        return (name, [full, address, name])
                    }
                }
                return (full, [full])
            }
            guard !recipients.isEmpty, recipients.count == chips.count else { return nil }
            // Modern Messages serializes committed chips into the To field as
            // "To:\u{FFFC}name". Reject any text not represented by those chips.
            var pending = address.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = address.description.isEmpty ? "To:" : address.description
            if pending.hasPrefix(prefix) { pending.removeFirst(prefix.count) }
            for recipient in recipients {
                for label in recipient.serialized {
                    if let range = pending.range(of: label, options: .caseInsensitive) { pending.removeSubrange(range); break }
                }
            }
            guard pending.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC},;"))).isEmpty else { return nil }
            return recipients.map(\.name).joined(separator: ", ")
        }
        guard let title = find(root, matching: { $0.identifier == "ConversationTitle" }) else { return nil }
        return normalizedContact([title.value, title.title, title.description].first { !$0.isEmpty } ?? "")
    }

    private static func isRecipientAddress(_ text: String) -> Bool {
        if text.range(of: #"^[^\s@,]+@[^\s@,]+\.[^\s@,]+$"#, options: .regularExpression) != nil { return true }
        let digits = text.filter(\.isNumber)
        return (text.hasPrefix("+") || text.contains("(")) && (7...15).contains(digits.count)
            && text.allSatisfy { $0.isNumber || "+()- .".contains($0) }
    }

    static func normalizedContact(_ title: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !["messages", "imessage", "sign in", "new message"].contains(name.lowercased()) else { return nil }
        return name
    }
}
