import Foundation

/// Presentation only. This detects an explicit spoken cue for caption styling;
/// it cannot execute a command or replace the authoritative attachment parser.
public struct FlowCommandCaption: Equatable, Sendable {
    public let message: String
    public let command: String

    private static let cue = try! NSRegularExpression(pattern: #"\b(?:hey\s+)?flow\s*[,;:.!?]*\s+(?:attach|find|search(?:\s+for)?)\b"#, options: [.caseInsensitive])
    private static let reported = try! NSRegularExpression(pattern: #"\b(?:said|says|say|told|tell|quote|quoted|phrase|tutorial|example|type|write|don['’]t|do\s+not|never)\b[^.!?]*$"#, options: [.caseInsensitive])
    private static let singleQuoted = try! NSRegularExpression(pattern: #"(?:^|\s|\(|\[|\{)['‘][^'’]*$"#)

    public static func detect(in transcript: String) -> Self? {
        guard transcript.utf16.count <= 20000,
              let match = cue.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range, in: transcript) else { return nil }
        let prefix = String(transcript[..<range.lowerBound])
        let prefixRange = NSRange(prefix.startIndex..., in: prefix)
        guard prefix.filter({ $0 == "\"" }).count % 2 == 0,
              prefix.filter({ $0 == "“" }).count <= prefix.filter({ $0 == "”" }).count,
              reported.firstMatch(in: prefix, range: prefixRange) == nil,
              singleQuoted.firstMatch(in: prefix, range: prefixRange) == nil else { return nil }
        return Self(message: prefix, command: String(transcript[range.lowerBound...]))
    }
}
