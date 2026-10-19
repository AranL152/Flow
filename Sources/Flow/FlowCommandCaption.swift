import Foundation

/// Presentation only. This detects an explicit spoken cue for caption styling;
/// it cannot execute a command or replace the authoritative attachment parser.
public struct FlowCommandCaption: Equatable, Sendable {
    public let message: String
    public let command: String

    // Keep aligned with the authoritative worker parser. Reused by provisional
    // rewriting so every supported command stays out of recipient text.
    public static let commandVerbPattern = #"(?:attach|add|include|insert|paste|append|enclose|upload|find|locate|fetch|retrieve|grab|get|select|pick(?:\s+out)?|search(?:\s+for)?|look\s+(?:for|up)|pull(?:\s+(?:up|in))?|bring(?:\s+(?:up|in))?|drop(?:\s+in)?|put)"#
    public static let commandPolitenessPattern = #"(?:(?:please|(?:can|could|would)\s+you)\s+)?(?:please\s+)?"#
    private static let cue = try! NSRegularExpression(pattern: #"\b(?:hey\s+)?flow\s*[,;:.!?]*\s+"# + commandPolitenessPattern + commandVerbPattern + #"\b"#, options: [.caseInsensitive])
    private static let reported = try! NSRegularExpression(pattern: #"\b(?:said|says|say|told|tell|quote|quoted|phrase|tutorial|example|type|write|don['’]t|do\s+not|never)\b[^.!?]*$"#, options: [.caseInsensitive])
    private static let singleQuoted = try! NSRegularExpression(pattern: #"(?:^|\s|\(|\[|\{)['‘][^'’]*$"#)

    public static func detect(in transcript: String, isRecording: Bool = false) -> Self? {
        // Partial live speech remains ordinary caption text. Stop is the explicit
        // end-of-utterance signal before a command can be visually recognized.
        guard !isRecording, transcript.utf16.count <= 20000,
              let match = cue.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range, in: transcript) else { return nil }
        let object = transcript[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !object.isEmpty else { return nil }
        let prefix = String(transcript[..<range.lowerBound])
        let prefixRange = NSRange(prefix.startIndex..., in: prefix)
        guard prefix.filter({ $0 == "\"" }).count % 2 == 0,
              prefix.filter({ $0 == "“" }).count <= prefix.filter({ $0 == "”" }).count,
              reported.firstMatch(in: prefix, range: prefixRange) == nil,
              singleQuoted.firstMatch(in: prefix, range: prefixRange) == nil else { return nil }
        return Self(message: prefix, command: String(transcript[range.lowerBound...]))
    }
}
