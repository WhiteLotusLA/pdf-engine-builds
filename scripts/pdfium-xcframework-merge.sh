#!/usr/bin/env bash
# Usage: scripts/pdfium-xcframework-merge.sh <macOS PDFium.xcframework.zip>
#
# Builds the three-slice dist/PDFium.xcframework (and dist/PDFium.xcframework.zip) from pieces that
# different CI jobs produced, without needing a PDFium checkout:
#   - the macOS slice and the Headers folder (module.modulemap at its root; PDFium/ with PDFium.h,
#     every fpdf*.h and every epdf_*.h)
#     come from the one-slice XCFramework that scripts/pdfium-xcframework.sh made in the macOS job
#     (the zip given as the argument);
#   - the iOS device and simulator libraries come from dist/slices/ios-arm64/libpdfium.a and
#     dist/slices/iossim-arm64/libpdfium.a, as scripts/pdfium-build.sh leaves them.
# The same Headers folder goes into every slice (the public headers do not depend on the platform).
# The three slices' BUILD-INFO.txt files must agree on pdfium_head, pdfium_branch and mode=embedpdf.
# The result must pass scripts/verify-xcframework.sh with exactly macos-arm64, ios-arm64 and
# ios-arm64-simulator; otherwise nothing is left behind.
#
# Environment (optional): DIST_DIR (default <repo>/dist).
# Exit codes: 0 ok, 2 usage or tool missing, 3 an input is missing or incomplete, 4 xcodebuild or the verification failed.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -eq 1 ] || die 2 "usage: $SCRIPT_NAME <macOS PDFium.xcframework.zip>"
MAC_ZIP="$1"
require_cmd xcodebuild ditto
[ -f "$MAC_ZIP" ] || die 3 "macOS framework zip not found: $MAC_ZIP"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-merge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$MAC_ZIP" "$TMP" || die 3 "cannot unzip $(basename "$MAC_ZIP") (not a valid zip file)"
MAC_XCF="$TMP/PDFium.xcframework"
MAC_LIB="$MAC_XCF/macos-arm64/libpdfium.a"
HEADERS="$MAC_XCF/macos-arm64/Headers"
[ -f "$MAC_LIB" ] || die 3 "$(basename "$MAC_ZIP") has no PDFium.xcframework/macos-arm64/libpdfium.a"
for f in module.modulemap PDFium/PDFium.h PDFium/fpdfview.h; do
  [ -f "$HEADERS/$f" ] || die 3 "$(basename "$MAC_ZIP") has no macos-arm64/Headers/$f"
done

IOS_LIB="$DIST_DIR/slices/ios-arm64/libpdfium.a"
SIM_LIB="$DIST_DIR/slices/iossim-arm64/libpdfium.a"
[ -f "$IOS_LIB" ] || die 3 "missing slice ios-arm64: $IOS_LIB"
[ -f "$SIM_LIB" ] || die 3 "missing slice iossim-arm64: $SIM_LIB"

# All three slices must come from the same PDFium checkout and the same mode: three CI jobs check the
# branch out separately, so a backport landing between them would otherwise give mixed-commit slices.
# The macOS BUILD-INFO.txt sits beside the zip as the macOS job uploaded it (slices/macos-arm64/).
MAC_INFO="$(dirname "$MAC_ZIP")/slices/macos-arm64/BUILD-INFO.txt"
[ -f "$MAC_INFO" ] || die 3 "missing BUILD-INFO.txt for macos-arm64 (expected slices/macos-arm64/BUILD-INFO.txt beside $(basename "$MAC_ZIP"))"
for id in ios-arm64 iossim-arm64; do
  [ -f "$DIST_DIR/slices/$id/BUILD-INFO.txt" ] || die 3 "missing BUILD-INFO.txt for slice $id"
done
for key in pdfium_head pdfium_branch mode; do
  want="$(sed -n "s/^$key=//p" "$MAC_INFO" | head -1)"
  [ -n "$want" ] || die 3 "macos-arm64 BUILD-INFO.txt has no $key line"
  for id in ios-arm64 iossim-arm64; do
    got="$(sed -n "s/^$key=//p" "$DIST_DIR/slices/$id/BUILD-INFO.txt" | head -1)"
    [ "$got" = "$want" ] || die 3 "slices differ in $key: macos-arm64 has '$want', $id has '${got:-nothing}'"
  done
done
[ "$(sed -n 's/^mode=//p' "$MAC_INFO" | head -1)" = embedpdf ] || die 3 "the slices were not built with the EmbedPDF patches (mode is not embedpdf)"

# The result is built beside the final name and moved into place only after it verifies.
STAGE="$TMP/out"
mkdir -p "$STAGE"
xcodebuild -create-xcframework \
  -library "$MAC_LIB" -headers "$HEADERS" \
  -library "$IOS_LIB" -headers "$HEADERS" \
  -library "$SIM_LIB" -headers "$HEADERS" \
  -output "$STAGE/PDFium.xcframework" >/dev/null || die 4 "xcodebuild -create-xcframework failed"
"$COMMON_SH_DIR/verify-xcframework.sh" "$STAGE/PDFium.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator \
  || die 4 "the merged framework failed verification; nothing was written to $DIST_DIR"
for id in macos-arm64 ios-arm64 ios-arm64-simulator; do
  [ -f "$STAGE/PDFium.xcframework/$id/Headers/module.modulemap" ] || die 4 "slice $id has no Headers/module.modulemap"
done

(cd "$STAGE" && ditto -c -k --keepParent PDFium.xcframework PDFium.xcframework.zip)
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/PDFium.xcframework" "$DIST_DIR/PDFium.xcframework.zip"
mv "$STAGE/PDFium.xcframework" "$DIST_DIR/PDFium.xcframework"
mv "$STAGE/PDFium.xcframework.zip" "$DIST_DIR/PDFium.xcframework.zip"
log "wrote $DIST_DIR/PDFium.xcframework with 3 slices and PDFium.xcframework.zip ($(wc -c <"$DIST_DIR/PDFium.xcframework.zip" | tr -d ' ') bytes)"
