import Foundation

/// Interim captions must never be promoted to final dictation by a timeout.
/// A backup must be a real recognizer final with a usable confidence score.
public enum SpeechFinalTranscript {
    public static func accepted(_ text: String, final: Bool, afterAudioEnd: Bool, confidence: Float) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final, afterAudioEnd, confidence.isFinite, (0.85...1).contains(confidence),
              !value.isEmpty, value.count <= 5000 else { return nil }
        return value
    }
}
