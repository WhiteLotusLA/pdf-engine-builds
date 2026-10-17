#!/usr/bin/env bash
# Self-test for scripts/verify-xcframework.sh. Builds tiny XCFrameworks (see tiny-xcframework.sh)
# and checks that the verifier accepts the good one and rejects: an extra expected slice, fewer
# expected slices, a missing slice, a wrong minimum OS, missing headers and a path that is not a
# framework.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "xcframework-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
VERIFY="$PWD/scripts/verify-xcframework.sh"
# versions.env is KEY=VALUE only, so it can be sourced here for MACOS_MIN and IOS_MIN.
# shellcheck source=../../versions.env
. "$PWD/versions.env"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/xcframework-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=tiny-xcframework.sh
. "$PWD/scripts/tests/tiny-xcframework.sh"
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

# --- lib-platform.sh on the four kinds of tiny library ---
PLATFORM="$PWD/scripts/lib-platform.sh"
expect_exit "lib-platform reads a macOS library" 0 "$PLATFORM" "$(tiny_lib mac)"
check "it prints MACOS and the pinned minimum" $([ "$out" = "MACOS $MACOS_MIN" ]; echo $?)
expect_exit "lib-platform reads an iOS device library" 0 "$PLATFORM" "$(tiny_lib ios)"
check "it prints IOS and the pinned minimum" $([ "$out" = "IOS $IOS_MIN" ]; echo $?)
expect_exit "lib-platform reads an iOS simulator library" 0 "$PLATFORM" "$(tiny_lib sim)"
check "it prints IOSSIMULATOR and the pinned minimum" $([ "$out" = "IOSSIMULATOR $IOS_MIN" ]; echo $?)
expect_exit "lib-platform reads an old-minimum library" 0 "$PLATFORM" "$(tiny_lib oldios)"
check "it prints the old minimum, not the pinned one" $([ "$out" = "IOS 17.0" ]; echo $?)
printf 'this is not a library\n' >"$WORK/text.a"
expect_exit "lib-platform refuses a file that is not a Mach-O library" 1 "$PLATFORM" "$WORK/text.a"
expect_exit "lib-platform without an argument is a usage error" 2 "$PLATFORM"

tiny_framework "$WORK/Good.xcframework" yes mac ios sim
expect_exit "a complete, correctly built framework passes" 0 "$VERIFY" "$WORK/Good.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator
expect_exit "expecting a slice the framework lacks fails" 1 "$VERIFY" "$WORK/Good.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator tvos-arm64
check "the failure says the slices differ" $(grep -q "slices differ" <<<"$out"; echo $?)
expect_exit "expecting fewer slices than the framework has fails" 1 "$VERIFY" "$WORK/Good.xcframework" macos-arm64 ios-arm64
expect_exit "a path that is not a framework fails" 1 "$VERIFY" "$WORK/nowhere.xcframework" macos-arm64
expect_exit "too few arguments is a usage error" 2 "$VERIFY" "$WORK/Good.xcframework"

tiny_framework "$WORK/TwoSlices.xcframework" yes mac ios
expect_exit "a framework missing the simulator slice fails" 1 "$VERIFY" "$WORK/TwoSlices.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator

tiny_framework "$WORK/OldMin.xcframework" yes mac oldios sim
expect_exit "an iOS slice with the wrong minimum OS fails" 1 "$VERIFY" "$WORK/OldMin.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator
check "the failure shows what it found" $(grep -q "built for" <<<"$out"; echo $?)

tiny_framework "$WORK/NoHeaders.xcframework" no mac ios sim
expect_exit "a framework without headers fails" 1 "$VERIFY" "$WORK/NoHeaders.xcframework" macos-arm64 ios-arm64 ios-arm64-simulator
check "the failure says the headers are missing" $(grep -q "Headers folder is missing" <<<"$out"; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "xcframework-test: $failures failure(s)"
  exit 1
fi
echo "xcframework-test: all passed"
