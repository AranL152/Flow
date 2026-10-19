import Foundation

/// Conservative provisional text only. Authoritative ASR/command parsing and
/// send learning still run once for the complete dictation after Stop.
public enum LiveRewritePresentation {
    public static func candidate(from transcript: String) -> String? {
        guard transcript.count <= 5000 else { return nil }
        var text: String
        if let command = FlowCommandCaption.detect(in: transcript) {
            text = command.message
        } else {
            // Do not let an unfinished reserved cue reach the rewriting model.
            let pending = #"(?i)\b(?:hey\s+)?flow\s*[,;:.!?]*(?:\s+"#
                + FlowCommandCaption.commandPolitenessPattern
                + #"(?:"# + FlowCommandCaption.commandVerbPattern + #"|look|please|can|could|would|can\s+you|could\s+you|would\s+you))?\s*[,;:.!?]*$"#
            if let range = transcript.range(of: pending, options: .regularExpression) {
                text = String(transcript[..<range.lowerBound])
            } else {
                // Recognition often revises its newest word. Leave it in the
                // live caption until the next update confirms more context.
                text = transcript.split(whereSeparator: \.isWhitespace).dropLast().joined(separator: " ")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isWhitespace).count >= 3 ? text : nil
    }

    /// Keep the previous rewrite visible while a replacement stream catches up;
    /// never blank a complete phrase just to reveal its first word again.
    public static func canDisplay(_ proposed: String, replacing current: String, completed: Bool = false) -> Bool {
        completed || proposed.count >= current.count
    }
}
