import Foundation

/// Line-oriented SSE decoder. A stream is usable only after its explicit done
/// event; EOF, errors and cancellation must never promote a partial draft.
public struct DemoStreamDecoder {
    public enum Event: Equatable { case delta(String), done(String) }
    private var name = ""
    private var data: [String] = []
    public private(set) var text = ""
    public private(set) var completed = false
    public init() {}

    public mutating func accept(line: String) throws -> Event? {
        guard !completed else { return nil }
        if line.isEmpty {
            defer { name = ""; data = [] }
            guard !data.isEmpty else { return nil }
            guard let encoded = data.joined(separator: "\n").data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw failure("Invalid stream data")
            }
            if name == "error" { throw failure(payload["error"] as? String ?? "Streaming failed") }
            guard let value = payload["text"] as? String else { throw failure("Missing stream text") }
            switch name {
            case "delta":
                text += value
                guard text.count <= 12000 else { throw failure("Stream output is too long") }
                return .delta(value)
            case "done":
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value == text.trimmingCharacters(in: .whitespacesAndNewlines) else { throw failure("Incomplete stream output") }
                completed = true
                return .done(value)
            default: throw failure("Unknown stream event")
            }
        }
        if line.hasPrefix("event:") { name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") {
            data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            guard data.reduce(0, { $0 + $1.count }) <= 50000 else { throw failure("Stream frame is too long") }
        }
        return nil
    }
    public func finish() throws {
        if !completed { throw failure("Connection ended before the message finished. Please retry.") }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "Flow.Stream", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
