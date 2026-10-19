import Foundation

/// Interim captions must never be promoted to final dictation by a timeout.
/// A backup must be a real recognizer final with a usable confidence score.
public enum SpeechFinalTranscript {
    public static func accepted(_ text: String, final: Bool, afterAudioEnd: Bool, confidence: Float,
                                corroboratingTranscript: String? = nil) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final, afterAudioEnd, confidence.isFinite, (0...1).contains(confidence),
              !value.isEmpty, value.count <= 5000 else { return nil }
        if confidence < 0.85 {
            // Independent recognizers agreeing on every word can corroborate a
            // lower-scored real final. A cloud prefix or a different name cannot.
            func words(_ text: String) -> [String] {
                text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            }
            let tokens = words(value)
            guard confidence >= 0.5, tokens.count >= 3, let corroboratingTranscript,
                  corroboratingTranscript.count <= 5000, words(corroboratingTranscript) == tokens else { return nil }
        }
        return value
    }
}
