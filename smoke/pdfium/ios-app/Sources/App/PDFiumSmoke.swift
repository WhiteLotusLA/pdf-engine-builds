import Foundation
internal import PDFium

/// Everything the iOS smoke test needs from PDFium: open a file, count pages, read page text.
/// PDFium is not thread-safe and Swift Testing runs tests in parallel, so every call takes one lock.
enum SmokeError: Error, Equatable {
    /// `FPDF_GetLastError()` after a failed open (FPDF_ERR_FILE is 2, FPDF_ERR_FORMAT is 3).
    case cannotOpen(code: UInt)
    case pageOutOfRange(index: Int, count: Int)
    case pageLoadFailed
}

enum PDFiumSmoke {
    private static let lock = NSLock()

    /// Initializes the library exactly once per process; a static let is initialized lazily and atomically.
    private static let libraryReady: Bool = {
        FPDF_InitLibrary()
        return true
    }()

    static func pageCount(of url: URL) throws -> Int {
        try withDocument(url) { document in Int(FPDF_GetPageCount(document)) }
    }

    static func text(of url: URL, page: Int) throws -> String {
        try withDocument(url) { document in
            let count = Int(FPDF_GetPageCount(document))
            guard page >= 0, page < count else {
                throw SmokeError.pageOutOfRange(index: page, count: count)
            }
            guard let loaded = FPDF_LoadPage(document, Int32(page)) else { throw SmokeError.pageLoadFailed }
            defer { FPDF_ClosePage(loaded) }
            guard let textPage = FPDFText_LoadPage(loaded) else { throw SmokeError.pageLoadFailed }
            defer { FPDFText_ClosePage(textPage) }
            let characters = Int(FPDFText_CountChars(textPage))
            guard characters > 0 else { return "" }
            // FPDFText_GetText writes UTF-16LE code units plus a terminating zero.
            var buffer = [UInt16](repeating: 0, count: characters + 1)
            let written = Int(FPDFText_GetText(textPage, 0, Int32(characters), &buffer))
            guard written > 1 else { return "" }
            return String(decoding: buffer[0 ..< (written - 1)], as: UTF16.self)
        }
    }

    private static func withDocument<T>(_ url: URL, _ body: (FPDF_DOCUMENT) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        precondition(libraryReady)
        guard let document = url.path.withCString({ FPDF_LoadDocument($0, nil) }) else {
            throw SmokeError.cannotOpen(code: FPDF_GetLastError())
        }
        defer { FPDF_CloseDocument(document) }
        return try body(document)
    }
}
