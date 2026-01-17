//
// WaveformView.swift
// FlowWispr
//
// Animated waveform visualization. The hero visual element.
//

import SwiftUI

struct WaveformView: View {
    let isRecording: Bool
    let barCount: Int

    @State private var animationPhase: CGFloat = 0

    init(isRecording: Bool, barCount: Int = 32) {
        self.isRecording = isRecording
        self.barCount = barCount
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            Canvas { context, size in
                let barWidth: CGFloat = 3
                let gap: CGFloat = 2
                let totalWidth = CGFloat(barCount) * (barWidth + gap) - gap
                let startX = (size.width - totalWidth) / 2
                let maxHeight = size.height * 0.8
                let minHeight: CGFloat = 4

                let time = timeline.date.timeIntervalSinceReferenceDate

                for i in 0..<barCount {
                    let x = startX + CGFloat(i) * (barWidth + gap)

                    // generate wave height based on position and time
                    let basePhase = Double(i) / Double(barCount) * .pi * 2
                    let timePhase = time * (isRecording ? 4 : 0.5)

                    let wave1 = sin(basePhase + timePhase) * 0.3
                    let wave2 = sin(basePhase * 2.3 + timePhase * 1.3) * 0.2
                    let wave3 = sin(basePhase * 0.7 + timePhase * 0.7) * 0.15

                    var amplitude = isRecording ? 0.5 + wave1 + wave2 + wave3 : 0.15 + wave1 * 0.2 + wave2 * 0.1
                    amplitude = max(0.05, min(1.0, amplitude))

                    let height = minHeight + (maxHeight - minHeight) * amplitude
                    let y = (size.height - height) / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                    let path = RoundedRectangle(cornerRadius: barWidth / 2)
                        .path(in: rect)

                    // color gradient based on position
                    let progress = CGFloat(i) / CGFloat(barCount - 1)
                    let color = isRecording
                        ? interpolateColor(from: FW.recording, to: FW.recording.opacity(0.6), progress: progress)
                        : interpolateColor(from: FW.accent, to: FW.accentSecondary, progress: progress)

                    context.fill(path, with: .color(color))
                }
            }
        }
    }

    private func interpolateColor(from: Color, to: Color, progress: CGFloat) -> Color {
        // simplified linear interpolation
        let nsFrom = NSColor(from)
        let nsTo = NSColor(to)

        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        nsFrom.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        nsTo.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return Color(
            red: r1 + (r2 - r1) * progress,
            green: g1 + (g2 - g1) * progress,
            blue: b1 + (b2 - b1) * progress,
            opacity: a1 + (a2 - a1) * progress
        )
    }
}

// MARK: - Compact waveform for menu bar

struct CompactWaveformView: View {
    let isRecording: Bool

    var body: some View {
        WaveformView(isRecording: isRecording, barCount: 12)
            .frame(width: 60, height: 24)
    }
}

// MARK: - Preview

#Preview("Idle") {
    WaveformView(isRecording: false)
        .frame(width: 300, height: 80)
        .padding()
        .background(Color.black.opacity(0.9))
}

#Preview("Recording") {
    WaveformView(isRecording: true)
        .frame(width: 300, height: 80)
        .padding()
        .background(Color.black.opacity(0.9))
}
