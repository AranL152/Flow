//
// GlobeKeyHandler.swift
// FlowWispr
//
// Captures the recording hotkey (Fn key or custom) using a CGEvent tap.
// Fn defaults to press-and-hold for recording.
// Requires "Accessibility" permission in System Settings > Privacy & Security.
//

import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class GlobeKeyHandler {
    enum Trigger {
        case pressed
        case released
        case toggle
    }

    private let fnHoldDelaySeconds: TimeInterval = 0.06
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onHotkeyTriggered: (@Sendable (Trigger) -> Void)?
    private var hotkey: Hotkey

    private var isFunctionDown = false
    private var functionUsedAsModifier = false
    private var pendingFnTrigger: DispatchWorkItem?

    init(hotkey: Hotkey, onHotkeyTriggered: @escaping @Sendable (Trigger) -> Void) {
        self.hotkey = hotkey
        self.onHotkeyTriggered = onHotkeyTriggered
        startListening(prompt: false)
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    func updateHotkey(_ hotkey: Hotkey) {
        self.hotkey = hotkey
        isFunctionDown = false
        functionUsedAsModifier = false
        pendingFnTrigger?.cancel()
        pendingFnTrigger = nil
    }

    @discardableResult
    func startListening(prompt: Bool) -> Bool {
        guard accessibilityTrusted(prompt: prompt) else { return false }
        guard eventTap == nil else { return true }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: globeKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    static func isAccessibilityAuthorized() -> Bool {
        accessibilityTrusted(prompt: false)
    }

    private static func accessibilityTrusted(prompt: Bool) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func accessibilityTrusted(prompt: Bool) -> Bool {
        Self.accessibilityTrusted(prompt: prompt)
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        switch hotkey.kind {
        case .globe:
            switch type {
            case .flagsChanged:
                handleFunctionFlagChange(event)
            case .keyDown:
                if isFunctionDown {
                    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                    if keycode != Int64(kVK_Function) {
                        functionUsedAsModifier = true
                        pendingFnTrigger?.cancel()
                        pendingFnTrigger = nil
                    }
                }
            default:
                break
            }
        case .custom:
            if type == .keyDown, matchesCustomHotkey(event) {
                fireHotkey(.toggle)
            }
        }
    }

    private func handleFunctionFlagChange(_ event: CGEvent) {
        let hasFn = event.flags.contains(.maskSecondaryFn)
        guard hasFn != isFunctionDown else { return }

        if hasFn {
            isFunctionDown = true
            functionUsedAsModifier = false
            pendingFnTrigger?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isFunctionDown, !self.functionUsedAsModifier else { return }
                self.fireHotkey(.pressed)
            }
            pendingFnTrigger = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + fnHoldDelaySeconds, execute: workItem)
            return
        }

        guard isFunctionDown else { return }
        isFunctionDown = false
        pendingFnTrigger?.cancel()
        pendingFnTrigger = nil

        if !functionUsedAsModifier {
            fireHotkey(.released)
        }
    }

    private func matchesCustomHotkey(_ event: CGEvent) -> Bool {
        guard case .custom(let keyCode, let modifiers, _) = hotkey.kind else { return false }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat { return false }

        let eventKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else { return false }

        return Hotkey.modifiersMatch(modifiers, eventFlags: event.flags)
    }

    private func fireHotkey(_ trigger: Trigger) {
        onHotkeyTriggered?(trigger)
    }
}

private func globeKeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let handler = Unmanaged<GlobeKeyHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
