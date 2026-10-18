import Foundation

/// A clocked history of measured input levels. Silence advances the history
/// even when the microphone keeps returning the same value.
public struct AudioWaveformHistory {
    public private(set) var samples: [Float]
    public private(set) var envelope: Float = 0

    public init(barCount: Int = 32) {
        samples = Array(repeating: 0, count: min(96, max(1, barCount)))
    }

    public mutating func tick(level: Float, recording: Bool) {
        let safe = level.isFinite ? min(1, max(0, level)) : 0
        // Fixed dB range, rather than normalizing every window: quiet speech
        // stays quieter than loud speech, and room noise stays near the floor.
        let target: Float = recording && safe > 0.004
            ? min(1, max(0, (20 * log10(safe) + 48) / 42)) : 0
        envelope += (target - envelope) * (target > envelope ? 0.72 : 0.24)
        if envelope < 0.006 { envelope = 0 }
        samples.removeFirst()
        samples.append(envelope)
    }
}
