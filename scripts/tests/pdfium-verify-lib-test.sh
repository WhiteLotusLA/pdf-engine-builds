#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-verify-lib.sh. Builds tiny stub archives with clang and libtool (macOS only).
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "pdfium-verify-lib-test: skipped (needs the macOS tools lipo, nm and libtool)"
  exit 0
fi
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-verify-lib.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-verify-lib-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

STOCK_SYMS="FPDF_InitLibraryWithConfig FPDF_DestroyLibrary FPDF_LoadDocument FPDF_LoadMemDocument FPDF_GetPageCount FPDF_LoadPage FPDF_ClosePage FPDF_GetLastError FPDFText_LoadPage FPDFText_GetText FPDF_SaveAsCopy FPDF_SaveWithVersion FPDFBookmark_GetFirstChild FPDFPage_CreateAnnot FPDF_ImportPagesByIndex"
EPDF_SYMS="EPDFPage_ApplyRedactions EPDFAnnot_ApplyRedaction EPDF_DigestBuffer"

# make_lib <out.a> <arch> <symbol...>: a static archive whose object defines each symbol as a function
make_lib() {
  local out="$1" arch="$2"
  shift 2
  : >"$WORK/stub.c"
  local s
  for s in "$@"; do
    echo "int $s(void) { return 0; }" >>"$WORK/stub.c"
  done
  clang -arch "$arch" -c "$WORK/stub.c" -o "$WORK/stub.o"
  rm -f "$out"
  libtool -static -o "$out" "$WORK/stub.o" 2>/dev/null
}

# without <list> <name>: the list minus one name
without() { echo "$1" | tr ' ' '\n' | grep -vx "$2" | tr '\n' ' '; }

run() { # <args...>: sets $out and $code
  set +e
  out="$("$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}

# shellcheck disable=SC2086
make_lib "$WORK/stock.a" arm64 $STOCK_SYMS
run "$WORK/stock.a"
check "a complete arm64 stock library passes" $([ "$code" -eq 0 ] && grep -q "stock library ok" <<<"$out"; echo $?)

# shellcheck disable=SC2086
make_lib "$WORK/missing.a" arm64 $(without "$STOCK_SYMS" FPDF_SaveAsCopy)
run "$WORK/missing.a"
check "a library without FPDF_SaveAsCopy fails and names the symbol" $([ "$code" -eq 1 ] && grep -q "symbol FPDF_SaveAsCopy is not defined" <<<"$out"; echo $?)

# shellcheck disable=SC2086
make_lib "$WORK/mislabelled.a" arm64 $STOCK_SYMS $EPDF_SYMS
run "$WORK/mislabelled.a"
check "a patched library checked as stock fails (EPDF symbols found)" $([ "$code" -eq 1 ] && grep -q "must not define EPDF symbols" <<<"$out"; echo $?)

run "$WORK/mislabelled.a" --embedpdf
check "the same library passes as --embedpdf" $([ "$code" -eq 0 ] && grep -q "embedpdf library ok" <<<"$out"; echo $?)

run "$WORK/stock.a" --embedpdf
check "a stock library checked as --embedpdf fails on the redaction entry point" $([ "$code" -eq 1 ] && grep -q "symbol EPDFPage_ApplyRedactions is not defined" <<<"$out"; echo $?)

# shellcheck disable=SC2086
make_lib "$WORK/x86.a" x86_64 $STOCK_SYMS
run "$WORK/x86.a"
check "an x86_64 archive fails the arm64 check" $([ "$code" -eq 1 ] && grep -q "architecture is 'x86_64', wanted 'arm64'" <<<"$out"; echo $?)

printf '!<thin>\n' >"$WORK/thin.a"
run "$WORK/thin.a"
check "a thin archive is rejected" $([ "$code" -eq 1 ] && grep -q "not a complete static archive" <<<"$out"; echo $?)

run "$WORK/does-not-exist.a"
check "a missing file exits 2" $([ "$code" -eq 2 ]; echo $?)
run
check "no argument exits 2" $([ "$code" -eq 2 ]; echo $?)
run "$WORK/stock.a" --nonsense
check "an unknown option exits 2" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-verify-lib-test: $failures failure(s)"; exit 1; fi
echo "pdfium-verify-lib-test: all passed"
