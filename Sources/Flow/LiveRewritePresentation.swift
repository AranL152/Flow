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
                text = transcript
            }
        }
        // Only punctuation followed by a word boundary ends a sentence. An
        // unfinished clause stays in the caption, never in a rewrite request.
        // Exclude decimal numbers, initials and common spoken abbreviations.
        let boundary = #"(?i)(?<!\bMr)(?<!\bMrs)(?<!\bMs)(?<!\bDr)(?<!\bProf)(?<!\bSr)(?<!\bJr)(?<!\be\.g)(?<!\bi\.e)[.!?]+[\"”’']*(?=\s|$)"#
        guard let pattern = try? NSRegularExpression(pattern: boundary),
              let match = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        let end = range.upperBound
        text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isWhitespace).count >= 2 ? text : nil
    }

    /// Once a completed sentence has been rewritten, only append new completed
    /// sentences. Earlier ASR revisions wait for authoritative final processing.
    public static func nextSentence(from transcript: String, after submitted: String) -> String? {
        guard let complete = candidate(from: transcript), complete.hasPrefix(submitted) else { return nil }
        let next = complete.dropFirst(submitted.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return next.isEmpty ? nil : next
    }

    /// Keep the previous rewrite visible while a replacement stream catches up;
    /// never blank a complete phrase just to reveal its first word again.
    public static func canDisplay(_ proposed: String, replacing current: String, completed: Bool = false) -> Bool {
        completed || proposed.count >= current.count
    }
}
