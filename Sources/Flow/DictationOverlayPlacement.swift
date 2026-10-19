import Foundation

/// Geometry only, in AppKit's global (bottom-up) coordinate space.
public enum DictationOverlayPlacement {
    public enum Side: String, CaseIterable, Sendable { case above, below, left, right, fallback }
    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        public let side: Side
    }

    public static func place(size: CGSize, composer: CGRect?, screens: [CGRect],
                             preferredSide: Side? = nil, avoiding: [CGRect] = []) -> Placement {
        let screens = screens.filter { valid($0) && $0.width > 24 && $0.height > 24 }
        let target = composer.flatMap { valid($0) ? $0 : nil }
        let screen = target.flatMap { target in
            screens.max { score($0, target: target) < score($1, target: target) }
        } ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bounds = screen.insetBy(dx: 12, dy: 12)
        let width = min(max(1, size.width.isFinite ? size.width : 500), bounds.width)
        let height = min(max(1, size.height.isFinite ? size.height : 190), bounds.height)
        func x(_ value: CGFloat) -> CGFloat { min(max(value, bounds.minX), bounds.maxX - width) }
        func y(_ value: CGFloat) -> CGFloat { min(max(value, bounds.minY), bounds.maxY - height) }
        let fallback = CGRect(x: x(bounds.midX - width / 2), y: bounds.minY, width: width, height: height)
        guard let target else { return Placement(frame: fallback, side: .fallback) }
        let gap: CGFloat = 18
        var sides = [Side.above, .below, .left, .right]
        if let preferredSide, let index = sides.firstIndex(of: preferredSide) {
            sides.remove(at: index); sides.insert(preferredSide, at: 0)
        }
        var candidates: [Placement] = []
        for side in sides {
            switch side {
            case .above, .below:
                let vertical = side == .above ? target.maxY + gap : target.minY - gap - height
                for horizontal in [target.midX - width / 2, target.minX, target.maxX - width, bounds.minX, bounds.maxX - width] {
                    candidates.append(Placement(frame: CGRect(x: x(horizontal), y: vertical, width: width, height: height), side: side))
                }
            case .left, .right:
                let horizontal = side == .left ? target.minX - gap - width : target.maxX + gap
                candidates.append(Placement(frame: CGRect(x: horizontal, y: y(target.midY - height / 2), width: width, height: height), side: side))
            case .fallback: break
            }
        }
        let protected = target.insetBy(dx: -12, dy: -12)
        let clear = candidates.filter { bounds.contains($0.frame) && !$0.frame.intersects(protected) }
        if let best = clear.first(where: { candidate in !avoiding.contains { $0.intersects(candidate.frame) } }) { return best }
        // The composer takes precedence over another Flow panel.
        if let best = clear.first { return best }

        // Very large composers can leave only a short strip. Keep captions out
        // of the field even then, using the largest available strip. The host
        // keeps its content aligned to the bottom so the capture pill stays visible.
        let strips = [
            CGRect(x: bounds.minX, y: max(bounds.minY, target.maxY + gap), width: bounds.width, height: max(0, bounds.maxY - target.maxY - gap)),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, target.minY - gap - bounds.minY)),
            CGRect(x: bounds.minX, y: bounds.minY, width: max(0, target.minX - gap - bounds.minX), height: bounds.height),
            CGRect(x: max(bounds.minX, target.maxX + gap), y: bounds.minY, width: max(0, bounds.maxX - target.maxX - gap), height: bounds.height)
        ].map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width >= 240 && $0.height >= 100 }
        if let strip = strips.max(by: { min($0.width, width) * min($0.height, height) < min($1.width, width) * min($1.height, height) }) {
            let compact = CGSize(width: min(width, strip.width), height: min(height, strip.height))
            let frame = CGRect(x: min(max(target.midX - compact.width / 2, strip.minX), strip.maxX - compact.width),
                               y: strip.minY, width: compact.width, height: compact.height)
            return Placement(frame: frame, side: .fallback)
        }
        // No rectangle can satisfy both constraints when the field occupies
        // essentially the entire display. Choose the least obstructive corner.
        let corners = [CGRect(x: bounds.minX, y: bounds.minY, width: width, height: height),
                       CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: height),
                       CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height),
                       CGRect(x: bounds.maxX - width, y: bounds.maxY - height, width: width, height: height)]
        let best = corners.min { area($0.intersection(protected)) < area($1.intersection(protected)) } ?? fallback
        return Placement(frame: best, side: .fallback)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    private static func score(_ screen: CGRect, target: CGRect) -> CGFloat {
        let overlap = area(screen.intersection(target))
        return overlap > 0 ? overlap : -hypot(screen.midX - target.midX, screen.midY - target.midY)
    }
}
