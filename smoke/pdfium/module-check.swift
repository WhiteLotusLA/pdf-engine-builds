// Compile-time check that the PDFium module map and umbrella header import into Swift.
// Used by smoke/pdfium/run-smoke.sh: swiftc -typecheck -I <Headers dir> module-check.swift
import PDFium

func pdfiumModuleLinks() -> UInt {
    FPDF_InitLibrary()
    defer { FPDF_DestroyLibrary() }
    let pageCount = Int(FPDF_GetPageCount(nil))
    precondition(pageCount == 0)
    return UInt(FPDF_GetLastError())
}
