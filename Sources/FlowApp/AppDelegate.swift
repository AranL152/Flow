//
// AppDelegate.swift
// Flow
//
// Handles window lifecycle: ensures window opens on launch and handles reopen.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var verificationWindow: NSWindow?
    func applicationDidFinishLaunching(_: Notification) {
        DispatchQueue.main.async { @MainActor in
            NSApp.setActivationPolicy(.regular)
            if ProcessInfo.processInfo.arguments.contains("--recording-preview") {
                let host = NSHostingController(rootView: RecordingPreviewView().environmentObject(AppState()))
                let window = NSWindow(contentViewController: host)
                window.title = "Flow Recording Verification"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.setContentSize(NSSize(width: 760, height: 480))
                window.center(); window.makeKeyAndOrderFront(nil)
                self.verificationWindow = window
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            WindowManager.openMainWindow()
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        WindowManager.openMainWindow()
        return true
    }
}
