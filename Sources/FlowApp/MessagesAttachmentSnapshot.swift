import AppKit
import ApplicationServices

/// Native object identities let a replacement select only the file Flow added.
/// Filenames and the user's other attachment objects are never used as anchors.
@MainActor
struct MessagesAttachmentSnapshot {
    struct Item {
        let element: AXUIElement
        let range: NSRange
    }
    let text: String
    let items: [Item]

    static func read(_ composer: AXUIElement) -> Self? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
              let length = (value as? NSNumber)?.intValue, (0...24000).contains(length) else { return nil }
        if length == 0 { return Self(text: "", items: []) }
        var range = CFRange(location: 0, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(composer, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let attributed = value as? NSAttributedString else { return nil }
        var items: [Item] = []
        attributed.enumerateAttribute(NSAttributedString.Key("AXAttachment"), in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID(), range.length == 1,
                  (attributed.string as NSString).substring(with: range) == "\u{FFFC}" else { return }
            items.append(Item(element: value as! AXUIElement, range: range))
        }
        return Self(text: attributed.string, items: items)
    }

    func contains(_ element: AXUIElement) -> Bool { items.contains { CFEqual($0.element, element) } }

    func added(comparedTo before: Self) -> [Item] { items.filter { !before.contains($0.element) } }

    func preservesObjects(in before: Self, excluding owned: AXUIElement? = nil) -> Bool {
        before.items.filter { item in owned.map { !CFEqual(item.element, $0) } ?? true }
            .allSatisfy { contains($0.element) }
    }
}
