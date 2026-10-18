#!/usr/bin/env bash
# Usage: smoke/qpdf/run-smoke.sh <slice> [path/to/QPDF.xcframework]
#   slice: macos-arm64 | ios-arm64 | iossim-arm64
#
# Compiles smoke/qpdf/smoke.cc against one slice of dist/QPDF.xcframework and links it.
#   macos-arm64   : runs the program (AES-256 round trip, /PageLabels, structural check)
#   ios-arm64     : links for the device and checks the platform; cannot run without a device
#   iossim-arm64  : links for the simulator and runs the program inside a simulator with
#                   `xcrun simctl spawn` (for CI; it boots an iPad simulator and leaves it booted)
# Exit codes: 0 ok, 1 smoke failed, 2 usage or missing input.
set -euo pipefail

# shellcheck source=../../scripts/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/common.sh"
load_versions
ROOT="$REPO_ROOT"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  die 2 "usage: run-smoke.sh <macos-arm64|ios-arm64|iossim-arm64> [QPDF.xcframework]"
fi
SLICE="$1"
XCF="${2:-$ROOT/dist/QPDF.xcframework}"

case "$SLICE" in
  macos-arm64) ID=macos-arm64; SDK=macosx; TARGET="arm64-apple-macos$MACOS_MIN"; PLATFORM=MACOS; MODE="run" ;;
  ios-arm64) ID=ios-arm64; SDK=iphoneos; TARGET="arm64-apple-ios$IOS_MIN"; PLATFORM=IOS; MODE="link" ;;
  iossim-arm64) ID=ios-arm64-simulator; SDK=iphonesimulator; TARGET="arm64-apple-ios$IOS_MIN-simulator"; PLATFORM=IOSSIMULATOR; MODE="simulator" ;;
  *) die 2 "unknown slice '$SLICE'" ;;
esac

LIB="$XCF/$ID/libqpdf.a"
INC="$XCF/$ID/Headers"
[ -f "$LIB" ] || die 2 "$LIB not found"
[ -d "$INC/qpdf" ] || die 2 "$INC/qpdf not found"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

xcrun --sdk "$SDK" clang++ -std=c++20 -O1 -Wall -Wextra -target "$TARGET" \
  -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" -I "$INC" \
  "$ROOT/smoke/qpdf/smoke.cc" "$LIB" -lz -o "$TMP/smoke"

# awk reads to the end (no early exit), so otool never gets SIGPIPE under pipefail.
built_for="$(otool -lv "$TMP/smoke" | awk '/^ *platform /{p = $2} END {print p}')"
if [ "$built_for" != "$PLATFORM" ]; then
  die 1 "the smoke binary was linked for '$built_for', wanted '$PLATFORM'"
fi

case "$MODE" in
  run)
    "$TMP/smoke" "$TMP"
    ;;
  link)
    log "linked for iOS device ($PLATFORM); not run (no device)"
    ;;
  simulator)
    UDID="$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key | test("iOS-27")) | .value[] | select(.name | startswith("iPad"))][0].udid // empty')"
    [ -n "$UDID" ] || die 2 "no available iPad simulator with iOS 27"
    # Arm64 code in a simulator runs on the macOS kernel and must carry at least an ad-hoc signature.
    codesign --force --sign - "$TMP/smoke"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    # Capture the output and require the success line, not only the exit status.
    sim_status=0
    xcrun simctl spawn "$UDID" "$TMP/smoke" "$TMP" >"$TMP/sim.out" 2>&1 || sim_status=$?
    cat "$TMP/sim.out"
    [ "$sim_status" -eq 0 ] || die 1 "the smoke program failed inside the simulator (exit $sim_status)"
    grep -qx 'qpdf smoke: all passed' "$TMP/sim.out" || die 1 "the simulator run did not print 'qpdf smoke: all passed'"
    ;;
esac
