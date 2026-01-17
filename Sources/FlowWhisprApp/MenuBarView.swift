//
// MenuBarView.swift
// FlowWhispr
//
// Menu bar dropdown content.
//

import FlowWhispr
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Text("FlowWhispr")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(appState.isConfigured ? .green : .orange)
                    .frame(width: 8, height: 8)
            }
            .padding()

            Divider()

            // recording button
            Button(action: { appState.toggleRecording() }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                        .foregroundStyle(appState.isRecording ? .red : .primary)
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                    Text("⌥ Space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if appState.isRecording {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(formatDuration(appState.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // current mode
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mode:")
                        .foregroundStyle(.secondary)
                    Text(appState.currentMode.displayName)
                    Spacer()
                }
                HStack {
                    Text("App:")
                        .foregroundStyle(.secondary)
                    Text(appState.currentApp)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .font(.caption)
            .padding()

            Divider()

            // mode picker
            Menu("Change Mode") {
                ForEach(WritingMode.allCases, id: \.self) { mode in
                    Button(action: { appState.setMode(mode) }) {
                        HStack {
                            Text(mode.displayName)
                            if mode == appState.currentMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // actions
            Button("Open FlowWhispr") {
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Button("Shortcuts...") {
                openWindow(id: "shortcuts")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Button("Settings...") {
                openSettings()
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
    }

    private func formatDuration(_ ms: UInt64) -> String {
        let seconds = ms / 1000
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
