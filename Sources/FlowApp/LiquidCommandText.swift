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
    var recognized = true
    var messagePrefix = ""
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.flowReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var raster: CGImage?
    @State private var lines: [CGRect] = []
    @State private var renderedKey: RasterKey?

    private struct RasterKey: Hashable {
        let text: String
        let prefix: String
        let width: CGFloat
        let scale: CGFloat
    }

    private var key: RasterKey { RasterKey(text: command, prefix: messagePrefix, width: width, scale: displayScale) }
    private func glyphs(mask: Bool = false, hideCommand: Bool = false) -> some View {
        (Text(messagePrefix).foregroundColor(mask ? .clear : .white.opacity(0.95))
            + Text(command).foregroundColor(hideCommand ? .clear : (mask ? .white : .white.opacity(0.95))))
            .font(.system(size: 16, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 3)
    }

    var body: some View {
        glyphs(hideCommand: recognized && raster != nil && renderedKey == key)
            .overlay(alignment: .topLeading) {
                if recognized, let raster, renderedKey == key {
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
                            if !active {
                                image.shading = .color(flashInk)
                                context.draw(image, in: bounds)
                            } else {
                                // Follow the actual glyph rows in reading order.
                                // A wrapped command gets one crest across all lines.
                                let total = lines.reduce(CGFloat(0)) { $0 + $1.width } + 120
                                var traveled: CGFloat = 0
                                for line in lines {
                                    let center = line.minX - 60 + total * progress - traveled
                                    traveled += line.width
                                    image.shading = .linearGradient(Gradient(colors: [FlowCommandBadge.ink,
                                        Color(red: 0.96, green: 0.90, blue: 1), FlowCommandBadge.ink]),
                                        startPoint: CGPoint(x: center - 50, y: 0), endPoint: CGPoint(x: center + 50, y: 0))
                                    for x in stride(from: CGFloat(0), to: size.width, by: 3) {
                                        let distance = x + 1.5 - center
                                        let envelope = exp(-(distance * distance) / (2 * 30 * 30))
                                        let fade = min(1, progress / 0.12, (1 - progress) / 0.12)
                                        var slice = context
                                        slice.clip(to: Path(CGRect(x: x, y: line.minY - 3, width: min(3, size.width - x), height: line.height + 6)))
                                        slice.translateBy(x: 0, y: -1.5 * envelope * fade)
                                        slice.draw(image, in: bounds)
                                    }
                                }
                            }
                        }
                        .shadow(color: FlowCommandBadge.ink.opacity(0.85 * settleFlash), radius: 9 * settleFlash)
                        .shadow(color: FlowCommandBadge.ink.opacity(0.60 * settleFlash), radius: 3 * settleFlash)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .task(id: recognized ? key : nil) {
                guard recognized, width > 0 else { return }
                let currentKey = key
                let renderer = ImageRenderer(content: glyphs(mask: true))
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                renderer.scale = displayScale
                guard let image = renderer.cgImage, !Task.isCancelled, currentKey == key else { return }
                lines = Self.inkLines(image, scale: displayScale)
                raster = image; renderedKey = currentKey
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attachment request: \(command)")
            .accessibilityIdentifier("flow-command-text")
    }
    /// Read the cached mask once, so the sweep follows the exact rendered lines
    /// including a command that starts midway through a message line.
    private static func inkLines(_ image: CGImage, scale: CGFloat) -> [CGRect] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var result: [CGRect] = []
        bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var start: Int?, left = w, right = 0, last = 0
        func flush() {
            guard let first = start else { return }
            result.append(CGRect(x: CGFloat(left) / scale, y: CGFloat(first) / scale,
                width: CGFloat(right - left + 1) / scale, height: CGFloat(last - first + 1) / scale))
            start = nil; left = w; right = 0
        }
        for y in 0..<h {
            var xs: [Int] = []
            for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 12 { xs.append(x) }
            if let first = xs.first, let end = xs.last {
                if start == nil { start = y }
                left = min(left, first); right = max(right, end); last = y
            } else if start != nil, y - last > max(2, Int(scale * 2)) { flush() }
        }
        flush()
        return result
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
