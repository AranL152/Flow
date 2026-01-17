//
// Hotkey.swift
// FlowWhispr
//
// Storage and display helpers for recording hotkeys.
//

import AppKit
import Carbon.HIToolbox
import Foundation

struct Hotkey: Equatable {
    enum Kind: Equatable {
        case globe
        case custom(keyCode: Int, modifiers: Modifiers, keyLabel: String)
    }

    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    private struct StoredHotkey: Codable {
        var kind: String
        var keyCode: Int?
        var modifiers: Int?
        var keyLabel: String?
    }

    static let storageKey = "recordHotkey"
    static let defaultHotkey = Hotkey(kind: .globe)

    let kind: Kind

    var displayName: String {
        switch kind {
        case .globe:
            return "Fn key"
        case .custom(_, let modifiers, let keyLabel):
            return "\(modifiers.displayString)\(keyLabel)"
        }
    }

    static func load() -> Hotkey {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return defaultHotkey
        }
        guard let stored = try? JSONDecoder().decode(StoredHotkey.self, from: data) else {
            return defaultHotkey
        }
        return fromStored(stored)
    }

    func save() {
        let stored = toStored()
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Hotkey.storageKey)
    }

    static func from(event: NSEvent) -> Hotkey {
        let modifiers = Modifiers.from(nsFlags: event.modifierFlags)
        let keyCode = Int(event.keyCode)
        let keyLabel = keyLabel(for: event)
        return Hotkey(kind: .custom(keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel))
    }

    static func modifiersMatch(_ modifiers: Modifiers, eventFlags: CGEventFlags) -> Bool {
        modifiers == Modifiers.from(cgFlags: eventFlags)
    }

    private func toStored() -> StoredHotkey {
        switch kind {
        case .globe:
            return StoredHotkey(kind: "globe", keyCode: nil, modifiers: nil, keyLabel: nil)
        case .custom(let keyCode, let modifiers, let keyLabel):
            return StoredHotkey(
                kind: "custom",
                keyCode: keyCode,
                modifiers: modifiers.rawValue,
                keyLabel: keyLabel
            )
        }
    }

    private static func fromStored(_ stored: StoredHotkey) -> Hotkey {
        if stored.kind == "custom",
           let keyCode = stored.keyCode,
           let modifiersRaw = stored.modifiers,
           let keyLabel = stored.keyLabel,
           !keyLabel.isEmpty {
            return Hotkey(
                kind: .custom(
                    keyCode: keyCode,
                    modifiers: Modifiers(rawValue: modifiersRaw),
                    keyLabel: keyLabel
                )
            )
        }

        return defaultHotkey
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let keyCode = Int(event.keyCode)
        if let label = specialKeyLabels[keyCode] {
            return label
        }

        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }

        return "Key \(keyCode)"
    }

    private static let specialKeyLabels: [Int: String] = [
        Int(kVK_Return): "Return",
        Int(kVK_Tab): "Tab",
        Int(kVK_Space): "Space",
        Int(kVK_Delete): "Delete",
        Int(kVK_Escape): "Esc",
        Int(kVK_ForwardDelete): "Forward Delete",
        Int(kVK_Help): "Help",
        Int(kVK_Home): "Home",
        Int(kVK_End): "End",
        Int(kVK_PageUp): "Page Up",
        Int(kVK_PageDown): "Page Down",
        Int(kVK_LeftArrow): "Left",
        Int(kVK_RightArrow): "Right",
        Int(kVK_DownArrow): "Down",
        Int(kVK_UpArrow): "Up",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12",
        Int(kVK_F13): "F13",
        Int(kVK_F14): "F14",
        Int(kVK_F15): "F15",
        Int(kVK_F16): "F16",
        Int(kVK_F17): "F17",
        Int(kVK_F18): "F18",
        Int(kVK_F19): "F19",
        Int(kVK_F20): "F20"
    ]
}

extension Hotkey.Modifiers {
    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    static func from(nsFlags: NSEvent.ModifierFlags) -> Hotkey.Modifiers {
        var modifiers: Hotkey.Modifiers = []
        if nsFlags.contains(.control) { modifiers.insert(.control) }
        if nsFlags.contains(.option) { modifiers.insert(.option) }
        if nsFlags.contains(.shift) { modifiers.insert(.shift) }
        if nsFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    static func from(cgFlags: CGEventFlags) -> Hotkey.Modifiers {
        var modifiers: Hotkey.Modifiers = []
        if cgFlags.contains(.maskControl) { modifiers.insert(.control) }
        if cgFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if cgFlags.contains(.maskShift) { modifiers.insert(.shift) }
        if cgFlags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }
}
