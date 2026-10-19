//
// AppDelegate.swift
// Flow
//
// Handles window lifecycle: ensures window opens on launch and handles reopen.
//

import AppKit
import SwiftUI
import Flow

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var verificationWindow: NSWindow?
    private var streamVerification: StreamInsertionVerification?
    func applicationDidFinishLaunching(_: Notification) {
        DispatchQueue.main.async { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--privacy-audit") {
                NSApp.setActivationPolicy(.accessory)
                Task { await NativePrivacyAudit.run() }
                return
            }
            NSApp.setActivationPolicy(.regular)
            if ProcessInfo.processInfo.arguments.contains("--voice-simulation") {
                let args = ProcessInfo.processInfo.arguments
                var downloads: AttachmentDownloads?
                if args.contains("--attachment-simulation"), let index = args.firstIndex(of: "--simulation-audio-dir"), args.indices.contains(index + 1) {
                    downloads = AttachmentDownloads(directory: URL(fileURLWithPath: args[index + 1]).appendingPathComponent("Downloads"))
                }
                let model = VoiceSimulationModel(state: AppState(attachmentDownloads: downloads), attachmentDownloads: downloads)
                let host = NSHostingController(rootView: VoiceSimulationView(model: model))
                let window = NSWindow(contentViewController: host)
                window.title = "Flow · Live Voice Simulation"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.setContentSize(NSSize(width: 1020, height: min(820, (NSScreen.main?.visibleFrame.height ?? 900) - 70)))
                window.center(); window.makeKeyAndOrderFront(nil)
                self.verificationWindow = window
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--stream-insertion-preview") {
                let verification = StreamInsertionVerification()
                self.streamVerification = verification
                verification.run()
                return
            }
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
