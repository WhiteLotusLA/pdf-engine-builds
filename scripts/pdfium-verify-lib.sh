#!/usr/bin/env bash
# Usage: scripts/pdfium-verify-lib.sh <libpdfium.a> [--embedpdf] [--arch arm64]
# Static checks on a built PDFium library (macOS tools: lipo, nm):
#   - it is a complete archive, not a thin one that points at object files elsewhere
#   - it holds the expected CPU architecture
#   - it defines the PDFium entry points the engine binding needs
#   - stock library: no EPDF symbols at all; --embedpdf library: the EmbedPDF redaction and digest entry points
# Exit codes: 0 ok, 1 a check failed (each printed as a FAIL line), 2 usage error or missing tool.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LIB=""
MODE=stock
ARCH=arm64
while [ "$#" -gt 0 ]; do
  case "$1" in
    --embedpdf) MODE=embedpdf ;;
    --arch)
      shift
      [ "$#" -gt 0 ] || die 2 "--arch needs a value"
      ARCH="$1"
      ;;
    -*) die 2 "unknown option: $1" ;;
    *)
      [ -z "$LIB" ] || die 2 "only one library path is allowed"
      LIB="$1"
      ;;
  esac
  shift
done
[ -n "$LIB" ] || die 2 "usage: $SCRIPT_NAME <libpdfium.a> [--embedpdf] [--arch arm64]"
[ -f "$LIB" ] || die 2 "library not found: $LIB"
require_cmd lipo nm

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

magic="$(head -c 7 "$LIB")"
if [ "$magic" != '!<arch>' ]; then
  fail "not a complete static archive (header is '$magic'); a thin archive would break once the build tree is gone"
fi

archs="$(lipo -archs "$LIB" 2>/dev/null || true)"
if [ "$archs" != "$ARCH" ]; then
  fail "architecture is '${archs:-unknown}', wanted '$ARCH'"
fi

SYMS="$(mktemp "${TMPDIR:-/tmp}/pdfium-syms.XXXXXX")"
trap 'rm -f "$SYMS"' EXIT
nm "$LIB" 2>/dev/null >"$SYMS" || true

REQUIRED="FPDF_InitLibraryWithConfig FPDF_DestroyLibrary FPDF_LoadDocument FPDF_LoadMemDocument FPDF_GetPageCount FPDF_LoadPage FPDF_ClosePage FPDF_GetLastError FPDFText_LoadPage FPDFText_GetText FPDF_SaveAsCopy FPDF_SaveWithVersion FPDFBookmark_GetFirstChild FPDFPage_CreateAnnot FPDF_ImportPagesByIndex"
if [ "$MODE" = embedpdf ]; then
  REQUIRED="$REQUIRED EPDFPage_ApplyRedactions EPDFText_RedactInRect EPDF_DigestBuffer"
fi
for name in $REQUIRED; do
  if ! grep -qE " [Tt] _${name}\$" "$SYMS"; then
    fail "symbol $name is not defined in the library"
  fi
done

epdf_count="$(grep -cE ' [Tt] _EPDF' "$SYMS" || true)"
if [ "$MODE" = stock ] && [ "$epdf_count" -gt 0 ]; then
  fail "a stock library must not define EPDF symbols, found $epdf_count (is this a patched build labelled stock?)"
fi

if [ "$failures" -gt 0 ]; then
  echo "pdfium-verify-lib: $failures check(s) failed"
  exit 1
fi
echo "pdfium-verify-lib: $MODE library ok ($ARCH, $(grep -cE ' [Tt] _FPDF' "$SYMS") FPDF entry points, $epdf_count EPDF entry points)"
