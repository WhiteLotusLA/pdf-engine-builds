#!/usr/bin/env bash
# shellcheck disable=SC2154
# Sourced by the XCFramework self-tests; do not run it. Builds tiny real XCFrameworks (one
# function per library) so tests can exercise scripts/verify-xcframework.sh and the release gate
# without a PDFium or qpdf build. Needs Xcode (clang, ar, xcodebuild -create-xcframework, which
# does not build anything) and the variables WORK (a scratch directory), MACOS_MIN and IOS_MIN.
#
#   tiny_framework <output .xcframework> <headers: yes|no> <kind>...
#     kinds: mac (macOS arm64), ios (iOS device), sim (iOS simulator), oldios (iOS device built
#     for iOS 17.0, an older minimum than versions.env pins)

tiny_lib() { # <kind> -> prints the path of $WORK/tiny/<kind>/libtiny.a, building it on first use
  # With TINY_SYMBOL set, the library defines that function instead of qb_tiny and lives in
  # $WORK/tiny/<kind>-<symbol>/ (the release gate's test gives PDFium and QPDF different symbols).
  # With TINY_EXTRA set, it also defines that function (the release gate requires an anchor symbol
  # per engine, such as FPDF_InitLibrary or qpdf_init) and lives in $WORK/tiny/<kind>[-<symbol>]-<extra>/.
  local kind="$1" sym="${TINY_SYMBOL:-qb_tiny}" extra="${TINY_EXTRA:-}" sdk target
  local dir="$WORK/tiny/$1${TINY_SYMBOL:+-$TINY_SYMBOL}${TINY_EXTRA:+-$TINY_EXTRA}"
  case "$kind" in
    mac) sdk=macosx; target="arm64-apple-macos$MACOS_MIN" ;;
    ios) sdk=iphoneos; target="arm64-apple-ios$IOS_MIN" ;;
    sim) sdk=iphonesimulator; target="arm64-apple-ios$IOS_MIN-simulator" ;;
    oldios) sdk=iphoneos; target="arm64-apple-ios17.0" ;;
    *) echo "tiny_lib: unknown kind $kind" >&2; return 2 ;;
  esac
  if [ ! -f "$dir/libtiny.a" ]; then
    mkdir -p "$dir"
    printf 'int %s(void) { return 7; }\n' "$sym" >"$dir/tiny.c"
    if [ -n "$extra" ]; then printf 'int %s(void) { return 8; }\n' "$extra" >>"$dir/tiny.c"; fi
    xcrun --sdk "$sdk" clang -c -O0 -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" "$dir/tiny.c" -o "$dir/tiny.o"
    ar rcs "$dir/libtiny.a" "$dir/tiny.o" 2>/dev/null
  fi
  printf '%s\n' "$dir/libtiny.a"
}

tiny_framework() { # <output> <yes|no> <kind>...
  local out="$1" headers="$2" kind args=()
  shift 2
  mkdir -p "$WORK/tiny/headers"
  printf 'int qb_tiny(void);\n' >"$WORK/tiny/headers/tiny.h"
  for kind in "$@"; do
    args+=(-library "$(tiny_lib "$kind")")
    if [ "$headers" = "yes" ]; then args+=(-headers "$WORK/tiny/headers"); fi
  done
  rm -rf "$out"
  xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null
}
