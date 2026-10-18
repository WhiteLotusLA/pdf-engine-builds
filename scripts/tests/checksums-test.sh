#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/checksums.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/checksums.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/checksums-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

run() { # <args...>: sets $out and $code
  set +e
  out="$("$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}

mkdir -p "$WORK/d"
printf 'alpha' >"$WORK/d/PDFium.xcframework.zip"
printf 'beta' >"$WORK/d/QPDF.xcframework.zip"

run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
check "write exits 0" $([ "$code" -eq 0 ]; echo $?)
check "checksums.txt has one line per asset, in the given order" \
  $([ "$(awk '{print $2}' "$WORK/d/checksums.txt" | tr '\n' ' ')" = "PDFium.xcframework.zip QPDF.xcframework.zip " ]; echo $?)
EXPECTED="$(printf 'alpha' | shasum -a 256 | awk '{print $1}')"
check "the first column is the SHA-256 of the file" $([ "$(awk '$2=="PDFium.xcframework.zip" {print $1}' "$WORK/d/checksums.txt")" = "$EXPECTED" ]; echo $?)
check "the line format is 'hash, two spaces, name' (what shasum -c reads)" $(grep -qE '^[0-9a-f]{64}  PDFium\.xcframework\.zip$' "$WORK/d/checksums.txt"; echo $?)

run verify "$WORK/d"
check "verify passes on untouched files" $([ "$code" -eq 0 ]; echo $?)

printf 'X' >>"$WORK/d/QPDF.xcframework.zip"
run verify "$WORK/d"
check "verify fails when one byte of an asset changes (exit 1)" $([ "$code" -eq 1 ] && grep -q "checksum verification failed" <<<"$out"; echo $?)

printf 'beta' >"$WORK/d/QPDF.xcframework.zip"
rm "$WORK/d/PDFium.xcframework.zip"
run verify "$WORK/d"
check "verify fails when an asset is missing (exit 1)" $([ "$code" -eq 1 ]; echo $?)

run write "$WORK/d" Missing.zip
check "write refuses an asset that does not exist (exit 3)" $([ "$code" -eq 3 ]; echo $?)
run write "$WORK/d" ../escape.zip
check "write refuses a path in an asset name (exit 2)" $([ "$code" -eq 2 ]; echo $?)
run write "$WORK/d"
check "write with no assets is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)
run verify "$WORK/nodir"
check "verify without checksums.txt exits 1" $([ "$code" -eq 1 ]; echo $?)
run bogus
check "an unknown command exits 2" $([ "$code" -eq 2 ]; echo $?)

# a malformed line beside a good one must not pass (shasum -c skips improperly formatted lines unless --strict)
printf 'alpha' >"$WORK/d/PDFium.xcframework.zip"
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
printf 'this line is not a checksum line\n' >>"$WORK/d/checksums.txt"
run verify "$WORK/d"
check "verify fails on a malformed line beside good ones (exit 1)" $([ "$code" -eq 1 ] && grep -q "checksum verification failed" <<<"$out"; echo $?)
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
run verify "$WORK/d"
check "verify passes again on a clean checksums.txt" $([ "$code" -eq 0 ]; echo $?)

# shasum -c picks the algorithm from each line's hex length and ignores -a 256, so SHA-1 (40 hex) and
# SHA-512 (128 hex) lines would verify; checksums.txt promises SHA-256, so verify refuses them
(cd "$WORK/d" && shasum -a 1 PDFium.xcframework.zip QPDF.xcframework.zip >checksums.txt)
run verify "$WORK/d"
check "verify refuses SHA-1 lines although they match the files (exit 1, names line 1)" \
  $([ "$code" -eq 1 ] && grep -q "checksum verification failed" <<<"$out" && grep -q "line 1 is not a SHA-256 line" <<<"$out"; echo $?)
(cd "$WORK/d" && shasum -a 512 PDFium.xcframework.zip QPDF.xcframework.zip >checksums.txt)
run verify "$WORK/d"
check "verify refuses SHA-512 lines although they match the files (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "line 1 is not a SHA-256 line" <<<"$out"; echo $?)
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
awk 'NR == 1 { print toupper($1) "  " $2 }' "$WORK/d/checksums.txt" >"$WORK/d/upper.txt"
mv "$WORK/d/upper.txt" "$WORK/d/checksums.txt"
run verify "$WORK/d"
check "verify refuses an uppercase hex digest (exit 1)" $([ "$code" -eq 1 ] && grep -q "line 1 is not a SHA-256 line" <<<"$out"; echo $?)

# asset names are plain file names: a line naming a file in a subfolder is refused even when it matches
mkdir -p "$WORK/d/sub"
printf 'gamma' >"$WORK/d/sub/extra.zip"
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
(cd "$WORK/d" && shasum -a 256 sub/extra.zip >>checksums.txt)
run verify "$WORK/d"
check "verify refuses a line whose name has a slash, although it matches (exit 1, names line 3)" \
  $([ "$code" -eq 1 ] && grep -q "line 3 is not a SHA-256 line" <<<"$out"; echo $?)

# binary-mode lines ("hash *name") are not what write produces
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
(cd "$WORK/d" && shasum -a 256 -b PDFium.xcframework.zip >checksums.txt)
run verify "$WORK/d"
check "verify refuses a binary-mode line ('hash *name') (exit 1)" $([ "$code" -eq 1 ] && grep -q "line 1 is not a SHA-256 line" <<<"$out"; echo $?)
run write "$WORK/d" PDFium.xcframework.zip QPDF.xcframework.zip
run verify "$WORK/d"
check "verify still passes on what write produces" $([ "$code" -eq 0 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "checksums-test: $failures failure(s)"; exit 1; fi
echo "checksums-test: all passed"
