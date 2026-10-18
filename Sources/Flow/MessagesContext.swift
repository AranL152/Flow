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
        return normalizedContact(title)
    }

    static func normalizedContact(_ title: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !["messages", "imessage", "sign in", "new message"].contains(name.lowercased()) else { return nil }
        return name
    }
}
