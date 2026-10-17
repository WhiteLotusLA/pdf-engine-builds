import Foundation
import Testing

@testable import PDFiumSmoke

@Suite("PDFium on iOS")
struct PDFiumSmokeTests {
    private static func fixtureURL() throws -> URL {
        try #require(Bundle.main.url(forResource: "three-pages", withExtension: "pdf"))
    }

    @Test("counts the pages of the bundled fixture")
    func countsPages() throws {
        #expect(try PDFiumSmoke.pageCount(of: Self.fixtureURL()) == 3)
    }

    @Test("extracts the text of each page")
    func extractsText() throws {
        let url = try Self.fixtureURL()
        for page in 0 ..< 3 {
            #expect(try PDFiumSmoke.text(of: url, page: page) == "page \(page + 1)")
        }
    }

    @Test("a page index past the end is an error, not a crash")
    func pageOutOfRange() throws {
        let url = try Self.fixtureURL()
        #expect(throws: SmokeError.pageOutOfRange(index: 3, count: 3)) {
            _ = try PDFiumSmoke.text(of: url, page: 3)
        }
    }

    @Test("a file that is not a PDF is refused with the format error")
    func notAPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        try Data("this is plain text, not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SmokeError.cannotOpen(code: 3)) {
            _ = try PDFiumSmoke.pageCount(of: url)
        }
    }

    @Test("a missing file is refused with the file error")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).pdf")
        #expect(throws: SmokeError.cannotOpen(code: 2)) {
            _ = try PDFiumSmoke.pageCount(of: url)
        }
    }
}
