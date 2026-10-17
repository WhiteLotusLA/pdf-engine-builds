#!/usr/bin/env bash
# Self-test for smoke/pdfium/ios-app/project.yml. Generates the Xcode project in a throwaway copy
# (xcodegen generate only; nothing is built) and checks the settings that matter: iPad only,
# iOS 27.0, Swift 6 with complete concurrency checking, the PDFium XCFramework linked but not
# embedded, the PDF fixture in the app's resources, and a hosted unit test target.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ios-app-project-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ios-app-project-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

command -v xcodegen >/dev/null 2>&1 || { echo "ios-app-project-test: xcodegen is not installed (brew install xcodegen)" >&2; exit 2; }

# Same relative layout as the repo, so ../../../dist/PDFium.xcframework resolves the same way.
mkdir -p "$WORK/smoke/pdfium"
cp -R "$REPO/smoke/pdfium/ios-app" "$WORK/smoke/pdfium/ios-app"
APP="$WORK/smoke/pdfium/ios-app"
rm -rf "$APP"/*.xcodeproj
xcodegen generate --spec "$APP/project.yml" --project "$APP" --quiet
PBX="$APP/PDFiumSmoke.xcodeproj/project.pbxproj"

check "the project was generated" $([ -f "$PBX" ]; echo $?)
check "every build configuration targets the iPad only (device family 2, never 1,2)" $(grep -q 'TARGETED_DEVICE_FAMILY = 2;' "$PBX" && ! grep -q 'TARGETED_DEVICE_FAMILY = "1,2"' "$PBX"; echo $?)
check "deployment target is iOS 27.0" $(grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 27.0;' "$PBX"; echo $?)
check "Swift 6 with complete strict concurrency" $(grep -q 'SWIFT_VERSION = 6.0;' "$PBX" && grep -q 'SWIFT_STRICT_CONCURRENCY = complete;' "$PBX"; echo $?)
check "the PDFium XCFramework is referenced at ../../../dist/PDFium.xcframework" $(grep -q 'path = ../../../dist/PDFium.xcframework;' "$PBX" && grep -q 'wrapper.xcframework' "$PBX"; echo $?)
check "the static framework is linked but not embedded" $(! grep -q 'Embed Frameworks' "$PBX" && ! grep -q 'dstSubfolderSpec = 10' "$PBX"; echo $?)
check "the fixture PDF is a bundle resource" $(grep -q 'three-pages.pdf in Resources' "$PBX"; echo $?)
check "the unit test target is hosted by the app" $(grep -q 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/PDFiumSmoke.app/PDFiumSmoke";' "$PBX"; echo $?)
check "the unit test target adds no second search path to the PDFium module map (it would redefine the module)" $(! grep -q 'SWIFT_INCLUDE_PATHS' "$PBX"; echo $?)
check "code signing is off for every configuration" $(grep -q 'CODE_SIGNING_ALLOWED = NO;' "$PBX" && ! grep -q 'CODE_SIGNING_ALLOWED = YES;' "$PBX"; echo $?)
check "the debug dylib split is off so PDFium symbols stay in the app binary" $(grep -q 'ENABLE_DEBUG_DYLIB = NO;' "$PBX" && ! grep -q 'ENABLE_DEBUG_DYLIB = YES;' "$PBX"; echo $?)
check "the scheme builds and tests both targets" $(grep -q 'PDFiumSmokeTests' "$APP/PDFiumSmoke.xcodeproj/xcshareddata/xcschemes/PDFiumSmoke.xcscheme"; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "ios-app-project-test: $failures failure(s)"
  exit 1
fi
echo "ios-app-project-test: all passed"
