#!/usr/bin/env python3
"""Writes the tiny smoke-test PDFs. The output is byte-for-byte deterministic.

Usage: make-fixtures.py <output-dir>

  hello.pdf   2 pages; page 1 reads "Hello PDFium smoke test", page 2 reads "Second page"
  redact.pdf  1 page; three lines: PUBLIC-LINE keep this / SECRET-4242 remove this / TRAILER-LINE keep this too

The files hold only invented text. They are plain uncompressed PDF 1.7 with a classic xref table.
"""
import sys
from pathlib import Path


def make_pdf(pages):
    """pages: a list of pages; each page is a list of (x, y, text) lines. Returns the PDF bytes."""
    count = len(pages)
    objs = {}
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    kids = " ".join("%d 0 R" % (4 + 2 * i) for i in range(count))
    objs[2] = ("<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, count)).encode("ascii")
    objs[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    for i, lines in enumerate(pages):
        page_no = 4 + 2 * i
        content_no = 5 + 2 * i
        body = "".join("BT /F1 24 Tf %d %d Td (%s) Tj ET\n" % (x, y, text) for x, y, text in lines).encode("ascii")
        objs[page_no] = (
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R "
            "/Resources << /Font << /F1 3 0 R >> >> >>" % content_no
        ).encode("ascii")
        objs[content_no] = ("<< /Length %d >>\nstream\n" % len(body)).encode("ascii") + body + b"endstream"

    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num in sorted(objs):
        offsets[num] = len(out)
        out += ("%d 0 obj\n" % num).encode("ascii") + objs[num] + b"\nendobj\n"
    xref_at = len(out)
    size = max(objs) + 1
    out += ("xref\n0 %d\n" % size).encode("ascii") + b"0000000000 65535 f \n"
    for num in range(1, size):
        out += ("%010d 00000 n \n" % offsets[num]).encode("ascii")
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, xref_at)).encode("ascii")
    return bytes(out)


FIXTURES = {
    "hello.pdf": [
        [(72, 700, "Hello PDFium smoke test")],
        [(72, 700, "Second page")],
    ],
    "redact.pdf": [
        [
            (72, 700, "PUBLIC-LINE keep this"),
            (72, 600, "SECRET-4242 remove this"),
            (72, 500, "TRAILER-LINE keep this too"),
        ],
    ],
}


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: make-fixtures.py <output-dir>\n")
        return 2
    outdir = Path(argv[1])
    outdir.mkdir(parents=True, exist_ok=True)
    for name, pages in FIXTURES.items():
        (outdir / name).write_bytes(make_pdf(pages))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
