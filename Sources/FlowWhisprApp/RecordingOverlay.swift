//
// RecordingOverlay.swift
// FlowWhispr
//
// Floating overlay shown during recording.
//

import SwiftUI

struct RecordingOverlay: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            // recording indicator
            ZStack {
                Circle()
                    .fill(.red.opacity(0.2))
                    .frame(width: 48, height: 48)

                Circle()
                    .fill(.red)
                    .frame(width: 20, height: 20)
                    .scaleEffect(appState.isRecording ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: appState.isRecording)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Recording")
                    .font(.headline)

                Text(formatDuration(appState.recordingDuration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("⌥ Space to stop")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: { appState.stopRecording() }) {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.red)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatDuration(_ ms: UInt64) -> String {
        let seconds = ms / 1000
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    RecordingOverlay()
        .environmentObject(AppState())
        .padding()
}
