#!/usr/bin/env bash
# Usage: scripts/qpdf-xcframework.sh
#
# Combines the three qpdf slices built by scripts/qpdf-build.sh
#   out/qpdf/macos-arm64   out/qpdf/ios-arm64   out/qpdf/iossim-arm64
# into dist/QPDF.xcframework (static libqpdf.a per slice with libjpeg-turbo merged in, headers
# under Headers/qpdf/) and dist/QPDF.xcframework.zip (the release asset).
#
# Environment (optional): OUT_DIR=<dir> (default <repo>/out), DIST_DIR=<dir> (default <repo>/dist).
# Exit codes: 0 ok, 2 tool missing, 3 a slice is missing or incomplete, 4 verification failed.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"

require_cmd xcodebuild ditto

# All-or-nothing: every slice must be complete before anything is written.
for slice in macos-arm64 ios-arm64 iossim-arm64; do
  if [ ! -f "$OUT_DIR/qpdf/$slice/libqpdf.a" ] || [ ! -f "$OUT_DIR/qpdf/$slice/Headers/qpdf/QPDF.hh" ]; then
    die 3 "missing slice $slice (expected $OUT_DIR/qpdf/$slice/libqpdf.a and Headers/qpdf/QPDF.hh)"
  fi
done

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/QPDF.xcframework" "$DIST_DIR/QPDF.xcframework.zip"

xcodebuild -create-xcframework \
  -library "$OUT_DIR/qpdf/macos-arm64/libqpdf.a" -headers "$OUT_DIR/qpdf/macos-arm64/Headers" \
  -library "$OUT_DIR/qpdf/ios-arm64/libqpdf.a" -headers "$OUT_DIR/qpdf/ios-arm64/Headers" \
  -library "$OUT_DIR/qpdf/iossim-arm64/libqpdf.a" -headers "$OUT_DIR/qpdf/iossim-arm64/Headers" \
  -output "$DIST_DIR/QPDF.xcframework"

"$COMMON_SH_DIR/verify-xcframework.sh" "$DIST_DIR/QPDF.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator \
  || { rm -rf "$DIST_DIR/QPDF.xcframework"; die 4 "verification failed; removed the framework"; }

(cd "$DIST_DIR" && ditto -c -k --keepParent QPDF.xcframework QPDF.xcframework.zip)
log "wrote $DIST_DIR/QPDF.xcframework and QPDF.xcframework.zip ($(stat -f %z "$DIST_DIR/QPDF.xcframework.zip") bytes)"
