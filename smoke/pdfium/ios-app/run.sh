#!/usr/bin/env bash
# Usage: smoke/pdfium/ios-app/run.sh simulator|device
#
#   simulator  generates the Xcode project, then runs `xcodebuild test` on an iPad simulator with
#              iOS 27: the Swift Testing tests call PDFium (page count, text, error codes) through
#              the iossim-arm64 slice of dist/PDFium.xcframework. Needs exactly 5 passing tests in the
#              result bundle (xcresulttool), none failed or skipped.
#   device     generates the project, then runs `xcodebuild build` for a generic iOS device with
#              code signing off: it proves the ios-arm64 slice links, that PDFium symbols are in
#              the app binary and that the binary is built for the iOS platform at IOS_MIN.
# CI only: it boots a simulator and writes DerivedData under work/. Needs dist/PDFium.xcframework
# (scripts/pdfium-xcframework.sh) and xcodegen (brew install xcodegen).
# Exit codes: 0 ok, 1 build or test failure, 2 usage or missing input.
set -euo pipefail

# shellcheck source=../../../scripts/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/common.sh"
load_versions
HERE="$REPO_ROOT/smoke/pdfium/ios-app"
DERIVED="$WORK_DIR/ios-app-derived"

[ "$#" -eq 1 ] || die 2 "usage: run.sh simulator|device"
MODE="$1"
case "$MODE" in simulator | device) ;; *) die 2 "usage: run.sh simulator|device" ;; esac
[ -f "$DIST_DIR/PDFium.xcframework/Info.plist" ] || die 2 "dist/PDFium.xcframework not found (run scripts/pdfium-xcframework.sh first)"
require_cmd xcodegen xcodebuild jq
require_env IOS_MIN

cd "$HERE"
rm -rf PDFiumSmoke.xcodeproj
xcodegen generate --spec project.yml --quiet
mkdir -p "$WORK_DIR"
LOG="$WORK_DIR/ios-app-$MODE.log"

case "$MODE" in
  simulator)
    require_cmd xcrun
    UDID="$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key | test("iOS-27")) | .value[] | select(.name | startswith("iPad"))][0].udid // empty')"
    [ -n "$UDID" ] || die 2 "no available iPad simulator with iOS 27 (xcrun simctl list devices available)"
    RESULT="$WORK_DIR/ios-app-simulator.xcresult"
    rm -rf "$RESULT"
    xcodebuild test -project PDFiumSmoke.xcodeproj -scheme PDFiumSmoke \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
      -resultBundlePath "$RESULT" \
      CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG" | grep -E 'Test run with|Test Case|error:|note: |\*\* TEST' || true
    grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG" || die 1 "xcodebuild test did not succeed (see $LOG)"
    # Count from the result bundle, not from console wording: exactly 5 passed, none failed or skipped.
    summary="$(xcrun xcresulttool get test-results summary --path "$RESULT" --compact)" || die 1 "cannot read $RESULT"
    counts="$(jq -r '"\(.passedTests) \(.failedTests) \(.skippedTests)"' <<<"$summary")"
    if [ "$counts" != "5 0 0" ]; then
      die 1 "expected 5 passed, 0 failed, 0 skipped tests; the result bundle says (passed failed skipped) $counts"
    fi
    log "simulator tests passed: PDFium ran on the iossim-arm64 slice"
    ;;
  device)
    xcodebuild build -project PDFiumSmoke.xcodeproj -scheme PDFiumSmoke \
      -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG" | grep -E 'error:|\*\* BUILD' || true
    grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG" || die 1 "xcodebuild build did not succeed (see $LOG)"
    APP_BINARY="$DERIVED/Build/Products/Debug-iphoneos/PDFiumSmoke.app/PDFiumSmoke"
    [ -f "$APP_BINARY" ] || die 1 "expected $APP_BINARY after the build"
    # nm into a file, not into grep -q: grep -q exits at the first match and pipefail would then fail on nm's SIGPIPE.
    nm "$APP_BINARY" >"$WORK_DIR/ios-app-device.nm" 2>/dev/null || die 1 "nm could not read $APP_BINARY"
    grep -q ' _FPDF_LoadDocument$' "$WORK_DIR/ios-app-device.nm" || die 1 "the app binary has no FPDF_LoadDocument: PDFium was not linked"
    [ "$("$REPO_ROOT/scripts/lib-platform.sh" "$APP_BINARY")" = "IOS $IOS_MIN" ] || die 1 "the app binary is not built for IOS $IOS_MIN"
    log "device build passed: PDFium links for the ios-arm64 slice"
    ;;
esac
