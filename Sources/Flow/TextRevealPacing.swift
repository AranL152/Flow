import Foundation

/// Small character updates at display cadence, with faster catch-up for bursts.
/// Never manufactures text or waits for an entire word to be available.
public enum TextRevealPacing {
    public static let frameInterval: Duration = .milliseconds(33)

    public static func charactersPerFrame(backlog: Int) -> Int {
        min(backlog, min(32, max(3, (backlog + 9) / 10)))
    }
}
