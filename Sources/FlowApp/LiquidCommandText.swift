import SwiftUI

/// A short ripple through cached glyph pixels. The caption is rasterized only
/// when its text/width changes; animation never relays out or moves message text.
@MainActor
struct LiquidCommandText: View {
    static let rippleDuration: TimeInterval = 0.7
    static let settleDuration: TimeInterval = 0.4
    static let animationDuration = rippleDuration + settleDuration
    let command: String
    let width: CGFloat
    let rippleStart: Date?
    let animating: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.flowReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var raster: CGImage?
    @State private var renderedKey: RasterKey?

    private struct RasterKey: Hashable {
        let text: String
        let width: CGFloat
        let scale: CGFloat
    }

    private var key: RasterKey { RasterKey(text: command, width: width, scale: displayScale) }
    private var glyphs: some View {
        Text(command)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(2).truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 3)
    }

    var body: some View {
        glyphs.foregroundStyle(FlowCommandBadge.ink)
            .opacity(raster != nil && renderedKey == key ? 0 : 1)
            .overlay(alignment: .topLeading) {
                if let raster, renderedKey == key {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating || reduceMotion)) { timeline in
                        let elapsed = rippleStart.map { timeline.date.timeIntervalSince($0) } ?? Self.animationDuration
                        let progress = animating && !reduceMotion ? min(1, max(0, elapsed / Self.rippleDuration)) : 1
                        let settling = (elapsed - Self.rippleDuration) / Self.settleDuration
                        let settleFlash = animating && !reduceMotion && settling > 0 && settling < 1
                            ? sin(settling * .pi) : 0
                        // One envelope drives both the luminous fill and outer halo,
                        // so the whole command blooms and settles in sync.
                        let flashInk = Color(red: 0.76 + 0.22 * settleFlash,
                                             green: 0.61 + 0.29 * settleFlash, blue: 1)
                        Canvas { context, size in
                            var image = context.resolve(Image(decorative: raster, scale: displayScale))
                            let bounds = CGRect(origin: .zero, size: size)
                            let active = progress > 0 && progress < 1
                            let center = -90 + (size.width + 180) * progress
                            image.shading = active
                                ? .linearGradient(Gradient(colors: [FlowCommandBadge.ink, FlowCommandBadge.ink,
                                                                   Color(red: 0.96, green: 0.90, blue: 1),
                                                                   FlowCommandBadge.ink, FlowCommandBadge.ink]),
                                                  startPoint: CGPoint(x: center - 85, y: 0),
                                                  endPoint: CGPoint(x: center + 85, y: 0))
                                : .color(flashInk)
                            if !active {
                                context.draw(image, in: bounds)
                            } else {
                                // Narrow strips distort the letters themselves instead
                                // of bouncing whole words or affecting the message.
                                for x in stride(from: CGFloat(0), to: size.width, by: 3) {
                                    let distance = x + 1.5 - center
                                    let envelope = exp(-(distance * distance) / (2 * 48 * 48))
                                    // One crest travels left to right with the highlight;
                                    // no oscillating carrier or trailing ripples.
                                    let fade = min(1, progress / 0.12, (1 - progress) / 0.12)
                                    let offset = -2.0 * envelope * fade
                                    var slice = context
                                    slice.clip(to: Path(CGRect(x: x, y: 0, width: min(3, size.width - x), height: size.height)))
                                    slice.translateBy(x: 0, y: offset)
                                    slice.draw(image, in: bounds)
                                }
                            }
                        }
                        .shadow(color: FlowCommandBadge.ink.opacity(0.85 * settleFlash), radius: 9 * settleFlash)
                        .shadow(color: FlowCommandBadge.ink.opacity(0.60 * settleFlash), radius: 3 * settleFlash)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .task(id: key) {
                guard width > 0 else { return }
                let currentKey = key
                let renderer = ImageRenderer(content: glyphs.foregroundStyle(.white).frame(width: width, alignment: .leading))
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                renderer.scale = displayScale
                guard let image = renderer.cgImage, !Task.isCancelled, currentKey == key else { return }
                raster = image; renderedKey = currentKey
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attachment request: \(command)")
            .accessibilityIdentifier("flow-command-text")
    }
}

struct FlowCommandBadge: View {
    static let ink = Color(red: 0.76, green: 0.61, blue: 1)
    var title = "Command"
    var onDarkSurface = false
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color { onDarkSurface || colorScheme == .dark ? Self.ink : FW.accentMuted }
    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold)).tracking(0.4)
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(ink.opacity(0.12)))
            .overlay(Capsule().strokeBorder(ink.opacity(0.25), lineWidth: 1))
            .fixedSize()
            .accessibilityIdentifier("flow-command-badge")
    }
}

// An app/preview can request less motion; it can never override the OS setting
// to enable motion when the user has disabled it.
private struct FlowReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var flowReduceMotion: Bool {
        get { self[FlowReduceMotionKey.self] }
        set { self[FlowReduceMotionKey.self] = newValue }
    }
}
