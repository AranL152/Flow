import Flow
import SwiftUI

/// Clocked at 30 Hz, including during constant silence. Every bar is a real
/// microphone-level sample with a quick attack and a gentler release.
struct WaveformView: View {
    let isRecording: Bool
    let barCount: Int
    let audioLevel: Float?
    @State private var history: AudioWaveformHistory
    @State private var latestLevel: Float = 0

    init(isRecording: Bool, barCount: Int = 32, audioLevel: Float? = nil) {
        self.isRecording = isRecording
        self.barCount = min(96, max(1, barCount))
        self.audioLevel = audioLevel
        _history = State(initialValue: AudioWaveformHistory(barCount: barCount))
    }

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = barCount < 16 ? 2.5 : 3
            let width = min(4, max(1.5, (size.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount)))
            let totalWidth = CGFloat(barCount) * width + CGFloat(barCount - 1) * gap
            let startX = (size.width - totalWidth) / 2
            for (index, sample) in history.samples.enumerated() {
                let height = max(2, CGFloat(sample) * size.height * 0.9)
                let rect = CGRect(x: startX + CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                let path = RoundedRectangle(cornerRadius: width / 2).path(in: rect)
                context.fill(path, with: .color((isRecording ? FW.recording : FW.accent).opacity(0.55 + Double(sample) * 0.45)))
            }
        }
        .accessibilityLabel(isRecording ? "Microphone level" : "Microphone idle")
        .onAppear { latestLevel = audioLevel ?? 0 }
        .onChange(of: audioLevel) { _, level in latestLevel = level ?? 0 }
        .task(id: isRecording) {
            if isRecording { history = AudioWaveformHistory(barCount: barCount) }
            while !Task.isCancelled {
                history.tick(level: latestLevel, recording: isRecording)
                if !isRecording && history.samples.allSatisfy({ $0 == 0 }) { break }
                do { try await Task.sleep(for: .seconds(1.0 / 30.0)) }
                catch { break }
            }
        }
    }
}

struct CompactWaveformView: View {
    let isRecording: Bool
    let audioLevel: Float?

    init(isRecording: Bool, audioLevel: Float? = nil) {
        self.isRecording = isRecording
        self.audioLevel = audioLevel
    }

    var body: some View {
        WaveformView(isRecording: isRecording, barCount: 15, audioLevel: audioLevel)
            .frame(width: 64, height: 22)
    }
}
