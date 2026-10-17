#!/usr/bin/env bash
# Self-test for scripts/pdfium-xcframework-merge.sh with tiny libraries (see tiny-xcframework.sh).
# Covers: a good merge gives a verified three-slice framework and a zip; a missing iOS slice, a
# macOS zip without a module map, an iOS slice built for the wrong minimum OS and two slices for
# the same platform each fail without touching an earlier dist/PDFium.xcframework.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "pdfium-xcframework-merge-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
MERGE="$REPO/scripts/pdfium-xcframework-merge.sh"
# shellcheck source=../../versions.env
. "$REPO/versions.env"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-merge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=tiny-xcframework.sh
. "$REPO/scripts/tests/tiny-xcframework.sh"
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
out=""
expect_exit() { # <label> <expected code> <command...>
  local label="$1" want="$2" got=0
  shift 2
  out="$("$@" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then echo "ok:   $label"; else echo "FAIL: $label (exit $got, wanted $want)"; failures=$((failures + 1)); fi
}

# The macOS one-slice framework as scripts/pdfium-xcframework.sh would leave it, zipped: the library
# is named libpdfium.a inside the slice (the merge script looks for exactly that name).
make_mac_zip() { # <zip path> <with module map: yes|no>
  local d="$WORK/macbuild"
  rm -rf "$d"
  mkdir -p "$d/lib" "$d/Headers/PDFium"
  cp "$(tiny_lib mac)" "$d/lib/libpdfium.a"
  printf '#include "fpdfview.h"\n' >"$d/Headers/PDFium/PDFium.h"
  printf 'typedef int FPDF_TEST;\n' >"$d/Headers/PDFium/fpdfview.h"
  if [ "$2" = yes ]; then
    printf 'module PDFium {\n  umbrella header "PDFium/PDFium.h"\n  export *\n  link "c++"\n}\n' >"$d/Headers/module.modulemap"
  fi
  xcodebuild -create-xcframework -library "$d/lib/libpdfium.a" -headers "$d/Headers" -output "$d/PDFium.xcframework" >/dev/null
  rm -f "$1"
  ditto -c -k --keepParent "$d/PDFium.xcframework" "$1"
}
put_slice() { # <dist> <slice dir name> <tiny kind>
  mkdir -p "$1/slices/$2"
  cp "$(tiny_lib "$3")" "$1/slices/$2/libpdfium.a"
}
run() { # <dist> <zip>
  DIST_DIR="$1" expect_exit "$3" "$4" "$MERGE" "$2"
}

make_mac_zip "$WORK/mac.zip" yes
D="$WORK/good"
put_slice "$D" ios-arm64 ios
put_slice "$D" iossim-arm64 sim
run "$D" "$WORK/mac.zip" "a good merge succeeds" 0
check "the result has exactly the three slices and passes the verifier" $("$REPO/scripts/verify-xcframework.sh" "$D/PDFium.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator >/dev/null 2>&1; echo $?)
check "every slice has the module map" $([ -f "$D/PDFium.xcframework/ios-arm64/Headers/module.modulemap" ] && [ -f "$D/PDFium.xcframework/ios-arm64-simulator/Headers/module.modulemap" ] && [ -f "$D/PDFium.xcframework/macos-arm64/Headers/module.modulemap" ]; echo $?)
check "every slice has the headers in Headers/PDFium" $([ -f "$D/PDFium.xcframework/ios-arm64/Headers/PDFium/PDFium.h" ] && [ -f "$D/PDFium.xcframework/ios-arm64-simulator/Headers/PDFium/fpdfview.h" ] && [ -f "$D/PDFium.xcframework/macos-arm64/Headers/PDFium/PDFium.h" ]; echo $?)
check "the zip has PDFium.xcframework at its top level" $(ditto -x -k "$D/PDFium.xcframework.zip" "$WORK/unzipped" && [ -f "$WORK/unzipped/PDFium.xcframework/Info.plist" ]; echo $?)

# Failures leave an earlier result alone.
fail_case() { # <name> <expected exit> <label>
  local d="$WORK/$1"
  mkdir -p "$d/PDFium.xcframework"
  echo old >"$d/PDFium.xcframework/old-marker"
  run "$d" "${ZIP_FOR_CASE:-$WORK/mac.zip}" "$3" "$2"
  check "$3: the earlier framework is untouched" $([ -f "$d/PDFium.xcframework/old-marker" ] && [ ! -f "$d/PDFium.xcframework.zip" ]; echo $?)
}

put_slice "$WORK/nosim" ios-arm64 ios
fail_case nosim 3 "a missing simulator slice (exit 3)"
check "the failure names the slice" $(grep -q "missing slice iossim-arm64" <<<"$out"; echo $?)

put_slice "$WORK/noios" iossim-arm64 sim
fail_case noios 3 "a missing device slice (exit 3)"

make_mac_zip "$WORK/mac-nomap.zip" no
put_slice "$WORK/nomap" ios-arm64 ios
put_slice "$WORK/nomap" iossim-arm64 sim
ZIP_FOR_CASE="$WORK/mac-nomap.zip" fail_case nomap 3 "a macOS framework without a module map (exit 3)"
check "the failure names the module map" $(grep -q "module.modulemap" <<<"$out"; echo $?)

put_slice "$WORK/oldmin" ios-arm64 oldios
put_slice "$WORK/oldmin" iossim-arm64 sim
fail_case oldmin 4 "an iOS slice built for iOS 17.0 (exit 4)"
check "the failure shows the platform it found" $(grep -q "built for" <<<"$out"; echo $?)

put_slice "$WORK/twosims" ios-arm64 sim
put_slice "$WORK/twosims" iossim-arm64 sim
fail_case twosims 4 "two simulator libraries for the device and the simulator slot (exit 4)"

expect_exit "no argument is a usage error" 2 "$MERGE"
expect_exit "a missing zip is an input error" 3 "$MERGE" "$WORK/nowhere.zip"

if [ "$failures" -gt 0 ]; then
  echo "pdfium-xcframework-merge-test: $failures failure(s)"
  exit 1
fi
echo "pdfium-xcframework-merge-test: all passed"
