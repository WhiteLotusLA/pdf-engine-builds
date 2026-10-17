#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-xcframework.sh with fake public headers and a stub static library (macOS only).
# Review focus: a newer upstream with renamed headers must fail the umbrella-header step loudly.
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "pdfium-xcframework-test: skipped (needs xcodebuild, ditto and clang)"
  exit 0
fi
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-xcframework.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-xcframework-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

STOCK="fpdfview.h fpdf_annot.h fpdf_attachment.h fpdf_catalog.h fpdf_dataavail.h fpdf_doc.h fpdf_edit.h fpdf_ext.h fpdf_flatten.h fpdf_formfill.h fpdf_fwlevent.h fpdf_javascript.h fpdf_ppo.h fpdf_progressive.h fpdf_save.h fpdf_searchex.h fpdf_signature.h fpdf_structtree.h fpdf_sysfontinfo.h fpdf_text.h fpdf_thumbnail.h fpdf_transformpage.h"
EPDF="epdf_action.h epdf_checkpoint.h epdf_digest.h epdf_font.h epdf_form.h epdf_measure.h epdf_named_pages.h epdf_pieceinfo.h epdf_redact.h epdf_signature.h epdf_text.h fpdf_jpeg.h fpdf_png.h"

# fake_header <path>: a tiny header with an include guard and one declaration
fake_header() {
  local base guard
  base="$(basename "$1" .h)"
  guard="FAKE_$(echo "$base" | tr 'a-z' 'A-Z')_H_"
  printf '#ifndef %s\n#define %s\ntypedef int %s_t;\n#endif\n' "$guard" "$guard" "$base" >"$1"
}

# fresh <patched yes|no>: a new fake checkout and a stub arm64 slice
fresh() {
  rm -rf "$WORK/w"
  mkdir -p "$WORK/w/pdfium/public" "$WORK/w/dist/slices/macos-arm64"
  local h
  for h in $STOCK; do fake_header "$WORK/w/pdfium/public/$h"; done
  if [ "$1" = yes ]; then
    for h in $EPDF; do fake_header "$WORK/w/pdfium/public/$h"; done
  fi
  echo 'int FPDF_GetPageCount(void) { return 0; }' >"$WORK/stub.c"
  clang -arch arm64 -c "$WORK/stub.c" -o "$WORK/stub.o"
  libtool -static -o "$WORK/w/dist/slices/macos-arm64/libpdfium.a" "$WORK/stub.o" 2>/dev/null
}

run() { # <args...>: sets $out and $code
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" TMPDIR="$WORK" WORK_DIR="$WORK/w" DIST_DIR="$WORK/w/dist" "$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}
XCF="$WORK/w/dist/PDFium.xcframework"
HDR="$XCF/macos-arm64/Headers"
PH="$HDR/PDFium"

# merged_import: copy the Headers folder next to another framework's headers in one include folder,
# as SwiftPM does for every static XCFramework a target uses, and import the module with incomplete-umbrella
# warnings turned into errors. With the umbrella header at the Headers root this fails on qpdf/QPDF.hh.
merged_import() {
  local inc="$WORK/merged-include"
  rm -rf "$inc" "$WORK/merged-cache" && mkdir -p "$inc/qpdf" && cp -R "$HDR"/. "$inc"/ &&
    printf '#ifndef FAKE_QPDF_HH_\n#define FAKE_QPDF_HH_\nint qpdf_fake(void);\n#endif\n' >"$inc/qpdf/QPDF.hh" &&
    printf '@import PDFium;\n' >"$WORK/merged.m" &&
    clang -fsyntax-only -fmodules -fmodules-cache-path="$WORK/merged-cache" -Werror=incomplete-umbrella \
      -I "$inc" "$WORK/merged.m" >/dev/null 2>&1
}

# --- happy path, stock ---
fresh no
run
check "stock build packs the XCFramework (exit 0)" $([ "$code" -eq 0 ]; echo $?)
check "the library identifier is macos-arm64" $([ "$(plutil -extract AvailableLibraries.0.LibraryIdentifier raw -o - "$XCF/Info.plist")" = "macos-arm64" ]; echo $?)
check "the static library is inside, named libpdfium.a" $([ -f "$XCF/macos-arm64/libpdfium.a" ]; echo $?)
check "the module map is exactly the contract text" \
  $([ "$(cat "$HDR/module.modulemap")" = "$(printf 'module PDFium {\n  umbrella header "PDFium/PDFium.h"\n  export *\n  link "c++"\n}')" ]; echo $?)
check "the Headers root holds only the module map and the PDFium folder" \
  $([ "$(ls -A "$HDR" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" = "PDFium module.modulemap " ]; echo $?)
check "the umbrella header includes fpdfview.h first" $([ "$(grep '^#include' "$PH/PDFium.h" | head -1)" = '#include "fpdfview.h"' ]; echo $?)
check "the umbrella header includes every staged header exactly once" \
  $([ "$(grep -c '^#include' "$PH/PDFium.h")" -eq 22 ] && [ "$(ls "$PH"/fpdf*.h | wc -l | tr -d ' ')" -eq 22 ]; echo $?)
check "a stock XCFramework has no epdf_ header" $([ -d "$PH" ] && [ -z "$(ls "$PH"/epdf_*.h 2>/dev/null || true)" ]; echo $?)
check "beside another framework's headers the module imports with no incomplete-umbrella warning" $(merged_import; echo $?)
check "the zip exists and has PDFium.xcframework/ at its top level" \
  $(unzip -l "$WORK/w/dist/PDFium.xcframework.zip" | awk '{print $4}' | grep -qx 'PDFium.xcframework/Info.plist'; echo $?)

# --- renamed header (review focus) ---
fresh no
rm "$WORK/w/pdfium/public/fpdf_save.h"
fake_header "$WORK/w/pdfium/public/fpdf_write.h"
# a framework and zip left over from an earlier run must not survive a failed run
mkdir -p "$XCF"
: >"$WORK/w/dist/PDFium.xcframework.zip"
run
check "a renamed header exits 3 and names the missing header" $([ "$code" -eq 3 ] && grep -q "required header(s) missing" <<<"$out" && grep -q "fpdf_save.h" <<<"$out"; echo $?)
check "no XCFramework and no zip are left behind" $([ ! -e "$XCF" ] && [ ! -e "$WORK/w/dist/PDFium.xcframework.zip" ]; echo $?)

# --- new, unknown header ---
fresh no
fake_header "$WORK/w/pdfium/public/fpdf_newthing.h"
run
check "an unknown new header is announced and still included" $([ "$code" -eq 0 ] && grep -q "fpdf_newthing.h" <<<"$out" && grep -q '#include "fpdf_newthing.h"' "$PH/PDFium.h"; echo $?)

# --- a header that does not compile ---
fresh no
printf '#error this header is broken\n' >"$WORK/w/pdfium/public/fpdf_text.h"
run
check "an umbrella header that does not compile exits 4" $([ "$code" -eq 4 ] && grep -q "does not compile as C" <<<"$out"; echo $?)

# --- stock build with EmbedPDF headers ---
fresh yes
run
check "a stock build refuses EmbedPDF headers (exit 3)" $([ "$code" -eq 3 ] && grep -q "stock build but the tree has EmbedPDF header" <<<"$out"; echo $?)

# --- patched build ---
fresh yes
run --embedpdf
check "patched build packs the XCFramework" $([ "$code" -eq 0 ]; echo $?)
check "the patched umbrella header includes epdf_redact.h" $(grep -q '#include "epdf_redact.h"' "$PH/PDFium.h"; echo $?)
fresh no
run --embedpdf
check "a patched build without epdf_redact.h exits 3" $([ "$code" -eq 3 ] && grep -q "epdf_redact.h" <<<"$out"; echo $?)

# --- no slice, bad usage ---
fresh no
rm -rf "$WORK/w/dist/slices"
run
check "no slice exits 3 and points at pdfium-build.sh" $([ "$code" -eq 3 ] && grep -q "pdfium-build.sh" <<<"$out"; echo $?)
run --nonsense
check "an unknown flag exits 2" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-xcframework-test: $failures failure(s)"; exit 1; fi
echo "pdfium-xcframework-test: all passed"
