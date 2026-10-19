//
// FlowApp.swift
// Flow
//
// Main app entry point with single-window architecture.
//

import SwiftUI

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    private var menuBarIcon: NSImage? {
        guard let iconURL = AppResources.bundle.url(forResource: "menubar", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL)
        else {
            return nil
        }
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    var body: some Scene {
        // main window
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--privacy-audit") || ProcessInfo.processInfo.arguments.contains("--recording-preview") || ProcessInfo.processInfo.arguments.contains("--stream-insertion-preview") || ProcessInfo.processInfo.arguments.contains("--voice-simulation") {
                EmptyView()
            } else if ProcessInfo.processInfo.arguments.contains("--demo") {
                DemoView().frame(minWidth: 1000, minHeight: 760)
            } else {
                ContentView().environmentObject(appState)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--demo") ? 1180 : WindowSize.width,
                     height: ProcessInfo.processInfo.arguments.contains("--demo") ? 850 : WindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // menu bar
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            if let icon = menuBarIcon {
                Image(nsImage: icon)
                    .padding(.top, 2)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
