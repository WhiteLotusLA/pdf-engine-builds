#!/usr/bin/env bash
# Usage: smoke/pdfium/run-smoke.sh <path/to/PDFium.xcframework> [--embedpdf]
# Links smoke.c against the macos-arm64 slice of the XCFramework and runs it on the fixtures:
#   1. the PDFium module imports from Swift (module-check.swift) and the umbrella header compiles
#   2. smoke.c opens hello.pdf, counts pages, extracts text, and checks the FPDF_ERR_FILE mapping
#   3. with --embedpdf: adds a redact annotation over SECRET-4242 in redact.pdf, applies it with
#      EPDFPage_ApplyRedactions, saves a full rewrite, reopens it and checks with FPDFText that the secret is
#      gone and the other lines remain. The same run with --skip-apply must FAIL, which proves the check bites.
# Prints status lines only. Exit codes: 0 all passed, 1 a smoke check failed, 2 usage error or missing tool,
# 3 the XCFramework does not have the expected slice, 4 a compile or link failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
. "$HERE/../../scripts/common.sh"

XCF="${1:-}"
MODE=stock
case "${2:-}" in
  '') ;;
  --embedpdf) MODE=embedpdf ;;
  *) die 2 "usage: $SCRIPT_NAME <PDFium.xcframework> [--embedpdf]" ;;
esac
[ -n "$XCF" ] || die 2 "usage: $SCRIPT_NAME <PDFium.xcframework> [--embedpdf]"
[ -d "$XCF" ] || die 3 "XCFramework not found: $XCF"
require_cmd clang swiftc

SLICE_DIR="$XCF/macos-arm64"
LIB="$SLICE_DIR/libpdfium.a"
HDR="$SLICE_DIR/Headers"
[ -f "$LIB" ] || die 3 "no macos-arm64/libpdfium.a inside $XCF"
[ -f "$HDR/PDFium/PDFium.h" ] && [ -f "$HDR/module.modulemap" ] || die 3 "no PDFium/PDFium.h or module.modulemap in $HDR"

OUT="${SMOKE_OUT:-$WORK_DIR/smoke}"
mkdir -p "$OUT"

log "importing the PDFium module from Swift"
swiftc -typecheck -parse-as-library -I "$HDR" "$HERE/module-check.swift" || die 4 "the PDFium module does not import in Swift"

CFLAGS=(-std=c11 -Wall -Wno-strict-prototypes -I "$HDR")
if [ "$MODE" = embedpdf ]; then
  CFLAGS+=(-DSMOKE_EPDF=1)
fi
log "compiling and linking smoke.c ($MODE)"
clang "${CFLAGS[@]}" "$HERE/smoke.c" "$LIB" -lc++ \
  -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework Foundation \
  -o "$OUT/smoke" || die 4 "smoke.c did not compile or link"

FIX="$HERE/fixtures"
status=0
"$OUT/smoke" "$FIX/hello.pdf" --pages 2 --contains "Hello PDFium smoke test" || status=1

if [ "$MODE" = embedpdf ]; then
  "$OUT/smoke" "$FIX/redact.pdf" --pages 1 --contains "PUBLIC-LINE" --redact "SECRET-4242" --keep "PUBLIC-LINE" || status=1
  "$OUT/smoke" "$FIX/redact.pdf" --pages 1 --contains "TRAILER-LINE" --redact "SECRET-4242" --keep "TRAILER-LINE" || status=1
  log "negative check: the same redaction run without the apply call must fail"
  set +e
  "$OUT/smoke" "$FIX/redact.pdf" --pages 1 --contains "PUBLIC-LINE" --redact "SECRET-4242" --keep "PUBLIC-LINE" --skip-apply >"$OUT/negative.log" 2>&1
  negative=$?
  set -e
  if [ "$negative" -ne 1 ] || ! grep -q "redacted text is gone from the saved copy FAILED" "$OUT/negative.log"; then
    log "the negative check did not fail the way it must (exit $negative); the redaction check cannot be trusted"
    status=1
  else
    log "negative check failed as it must"
  fi
else
  "$OUT/smoke" "$FIX/redact.pdf" --pages 1 --contains "SECRET-4242" || status=1
fi

if [ "$status" -ne 0 ]; then
  log "smoke run FAILED"
  exit 1
fi
log "smoke run passed ($MODE)"
