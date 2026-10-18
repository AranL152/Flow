import XCTest
@testable import Flow

final class AttachmentFileSearchTests: XCTestCase {
    @MainActor
    func testResultsFilterNamesTypesLinksPartialAndHiddenFilesAndRevalidate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FlowSearch-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["Beach Trip.jpg", "beach trip.pdf", "beach unrelated.jpg", "Beach Trip.jpg.part", ".beach trip.jpg"]
        let urls = try names.map { name in
            let url = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let link = folder.appendingPathComponent("beach trip link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: urls[0])
        let results = AttachmentFileSearch.candidates(from: urls + [link, urls[0]], text: "beach trip", kind: .image)
        XCTAssertEqual(results.map(\.filename), ["Beach Trip.jpg"])
        try results[0].validate()
        try Data("changed image".utf8).write(to: urls[0])
        XCTAssertThrowsError(try results[0].validate())
    }

    @MainActor
    func testSearchTermsAreLiteralAndDoNotAcceptPathsOrUnboundedQueries() throws {
        XCTAssertEqual(try AttachmentFileSearch.terms(for: "  Café trip  "), ["Café", "trip"])
        for text in ["", "  ", "/etc/passwd", "..\\secret", "robotics\nsecret", String(repeating: "x", count: 161)] {
            XCTAssertThrowsError(try AttachmentFileSearch.terms(for: text))
        }
        XCTAssertEqual(try AttachmentFileSearch.terms(for: "name* OR invoice"), ["name*", "OR", "invoice"])
    }
}
