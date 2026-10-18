import Foundation

/// Owns exactly one selected range. Later writes are allowed only while both
/// the field and selection still match our last acknowledged write.
public struct StreamInsertionBuffer {
    public struct Update {
        public let text: String
        public let replacementRange: NSRange
        public let selection: NSRange
        fileprivate let output: String
    }
    public let original: String
    public let originalSelection: NSRange
    public private(set) var expectedText: String
    public private(set) var expectedSelection: NSRange
    public private(set) var insertionRange: NSRange
    private let prefix: String
    private let suffix: String

    public init(original: String, selection: NSRange) throws {
        let units = Array(original.utf16)
        guard selection.location >= 0, selection.length >= 0, selection.location <= units.count,
              selection.length <= units.count - selection.location else { throw Self.failure("Invalid insertion selection") }
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < units.count && (0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset])
        }
        guard !splitsSurrogate(selection.location), !splitsSurrogate(NSMaxRange(selection)),
              let range = Range(selection, in: original) else { throw Self.failure("Invalid insertion selection") }
        self.original = original; originalSelection = selection
        expectedText = original; expectedSelection = selection; insertionRange = selection
        prefix = String(original[..<range.lowerBound]); suffix = String(original[range.upperBound...])
    }

    public func propose(output: String, observedText: String, observedSelection: NSRange) throws -> Update {
        guard observedText == expectedText, observedSelection == expectedSelection else {
            throw Self.failure("The draft was edited or the cursor moved")
        }
        guard output.utf16.count <= 24000 else { throw Self.failure("Draft is too long") }
        let caret = NSRange(location: originalSelection.location + output.utf16.count, length: 0)
        return Update(text: prefix + output + suffix, replacementRange: insertionRange, selection: caret, output: output)
    }

    public mutating func acknowledge(_ update: Update) {
        expectedText = update.text; expectedSelection = update.selection
        insertionRange = NSRange(location: originalSelection.location, length: update.output.utf16.count)
    }

    public func canRestore(observedText: String, observedSelection: NSRange) -> Bool {
        observedText == expectedText && observedSelection == expectedSelection
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Flow.Insertion", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
