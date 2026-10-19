import AppKit
import ApplicationServices

/// Captures one Messages composer without inspecting its text or moving focus.
/// Read the same element throughout a recording, even while its frame grows.
@MainActor
final class RecordingComposerAnchor {
    private let app: NSRunningApplication
    private let element: AXUIElement

    init?(app: NSRunningApplication?) {
        guard AXIsProcessTrusted(), let app, app.bundleIdentifier == "com.apple.MobileSMS", !app.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var budget = 180
        guard let element = Self.composer(in: raw as! AXUIElement, depth: 0, budget: &budget) else { return nil }
        self.app = app; self.element = element
        AXUIElementSetMessagingTimeout(element, 0.05)
    }

    var frame: CGRect? {
        guard !app.isTerminated else { return nil }
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size),
              [position.x, position.y, size.width, size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: position.x, y: primary.frame.maxY - position.y - size.height, width: size.width, height: size.height)
    }

    private static func composer(in element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 18, budget > 0 else { return nil }; budget -= 1
        var raw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &raw)
        let identifier = raw as? String ?? ""
        if identifier == "messageBodyField" { return element }
        if ["ConversationList", "TranscriptCollectionView"].contains(identifier) { return nil }
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        for child in raw as? [AXUIElement] ?? [] {
            if let result = composer(in: child, depth: depth + 1, budget: &budget) { return result }
        }
        return nil
    }
}
