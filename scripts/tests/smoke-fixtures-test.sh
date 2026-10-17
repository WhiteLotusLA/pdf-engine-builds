#!/usr/bin/env bash
# shellcheck disable=SC2046
# Checks the committed smoke fixtures: deterministic (regenerating gives the same bytes), structurally sound
# (every xref offset points at its object) and tiny. poppler tools are used too when they are installed.
set -euo pipefail
cd "$(dirname "$0")/../.."
FIXDIR="smoke/pdfium/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/smoke-fixtures-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# xref_ok <file>: exit 0 when the classic xref table of the file points at every object
xref_ok() {
  python3 -I - "$1" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read()
start = int(re.search(rb"startxref\n(\d+)\n%%EOF\n$", data).group(1))
assert data[start:start + 5] == b"xref\n", "startxref does not point at xref"
lines = data[start:].split(b"\n")
count = int(lines[1].split()[1])
for num in range(1, count):
    offset = int(lines[2 + num][:10])
    assert data[offset:].startswith(b"%d 0 obj\n" % num), "object %d is not at offset %d" % (num, offset)
PY
}

if [ ! -f "$FIXDIR/hello.pdf" ] || [ ! -f "$FIXDIR/redact.pdf" ]; then
  echo "FAIL: fixtures are missing in $FIXDIR (run: python3 smoke/pdfium/make-fixtures.py $FIXDIR)"
  echo "smoke-fixtures-test: 1 failure(s)"
  exit 1
fi

python3 -I smoke/pdfium/make-fixtures.py "$WORK/regen"
for name in hello.pdf redact.pdf; do
  check "$name is byte-identical to a fresh generation" $(cmp -s "$FIXDIR/$name" "$WORK/regen/$name"; echo $?)
  check "$name is under 4 KB" $([ "$(wc -c <"$FIXDIR/$name" | tr -d ' ')" -lt 4096 ]; echo $?)
  check "$name starts with %PDF-1.7 and ends with %%EOF" $([ "$(head -c 8 "$FIXDIR/$name")" = "%PDF-1.7" ] && [ "$(tail -c 6 "$FIXDIR/$name" | tr -d '\n')" = "%%EOF" ]; echo $?)
  check "$name: every xref offset points at its object" $(xref_ok "$FIXDIR/$name" >/dev/null 2>&1; echo $?)
done

check "redact.pdf holds the three expected lines in plain text" \
  $(grep -aq "(PUBLIC-LINE keep this)" "$FIXDIR/redact.pdf" && grep -aq "(SECRET-4242 remove this)" "$FIXDIR/redact.pdf" && grep -aq "(TRAILER-LINE keep this too)" "$FIXDIR/redact.pdf"; echo $?)

if command -v pdfinfo >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1; then
  check "poppler: hello.pdf has 2 pages" $([ "$(pdfinfo "$FIXDIR/hello.pdf" | awk '/^Pages:/ {print $2}')" = "2" ]; echo $?)
  check "poppler: hello.pdf page 1 reads 'Hello PDFium smoke test'" $(pdftotext -f 1 -l 1 "$FIXDIR/hello.pdf" - | grep -q "Hello PDFium smoke test"; echo $?)
  check "poppler: redact.pdf has 1 page and the secret line" $([ "$(pdfinfo "$FIXDIR/redact.pdf" | awk '/^Pages:/ {print $2}')" = "1" ] && pdftotext "$FIXDIR/redact.pdf" - | grep -q "SECRET-4242 remove this"; echo $?)
else
  echo "note: pdfinfo or pdftotext not installed, poppler checks skipped"
fi

if [ "$failures" -gt 0 ]; then echo "smoke-fixtures-test: $failures failure(s)"; exit 1; fi
echo "smoke-fixtures-test: all passed"
