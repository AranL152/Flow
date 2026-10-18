import SwiftUI

/// A steady label with a small left-to-right typing wave, only while listening.
struct ListeningStatusLabel: View {
    var fontSize: CGFloat = 9
    var weight: Font.Weight = .semibold
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.flowReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("Listening").font(.system(size: fontSize, weight: weight))
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3) { index in
                        let phase = timeline.date.timeIntervalSinceReferenceDate / 1.1 - Double(index) * 0.16
                        let wave = reduceMotion ? 0 : pow(max(0, sin(phase * 2 * .pi)), 2)
                        Circle()
                            .fill(FlowCommandBadge.ink.opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * wave))
                            .frame(width: 2.5, height: 2.5)
                            .offset(y: -2 * wave)
                    }
                }
                .frame(width: 12, height: 8, alignment: .bottom)
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        }
        .foregroundStyle(FlowCommandBadge.ink)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening")
        .accessibilityIdentifier("flow-listening-status")
    }
}
