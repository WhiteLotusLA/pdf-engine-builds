#!/usr/bin/env bash
# Usage: scripts/verify-xcframework.sh <path/to/Name.xcframework> <library identifier>...
#   identifiers: macos-arm64 | ios-arm64 | ios-arm64-simulator
#
# Checks an XCFramework of static libraries:
#   - the set of slices is exactly the identifiers given (no more, no fewer)
#   - each slice has its library, a thin arm64 one, and a non-empty Headers folder
#   - each library was built for the right platform and minimum OS (MACOS_MIN or IOS_MIN from
#     versions.env), so a macOS library cannot sit in an iOS slice and an old deployment target
#     cannot slip through
# Exit codes: 0 ok, 1 a check failed, 2 usage.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

if [ "$#" -lt 2 ]; then
  die 2 "usage: verify-xcframework.sh <path/to/Name.xcframework> <library identifier>..."
fi
XCF="$1"
shift
[ -f "$XCF/Info.plist" ] || die 1 "$XCF/Info.plist not found"
require_cmd plutil jq lipo

libs_json="$(plutil -extract AvailableLibraries json -o - "$XCF/Info.plist")"
actual="$(jq -r '.[].LibraryIdentifier' <<<"$libs_json" | sort | tr '\n' ' ')"
wanted="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
[ "$actual" = "$wanted" ] || die 1 "slices differ: found '${actual% }', wanted '${wanted% }'"

for id in "$@"; do
  case "$id" in
    macos-arm64) require_env MACOS_MIN; platform=MACOS; minos="$MACOS_MIN" ;;
    ios-arm64) require_env IOS_MIN; platform=IOS; minos="$IOS_MIN" ;;
    ios-arm64-simulator) require_env IOS_MIN; platform=IOSSIMULATOR; minos="$IOS_MIN" ;;
    *) die 1 "unknown library identifier: $id" ;;
  esac
  libpath="$(jq -r --arg id "$id" '.[] | select(.LibraryIdentifier == $id) | .LibraryPath' <<<"$libs_json")"
  headers="$(jq -r --arg id "$id" '.[] | select(.LibraryIdentifier == $id) | .HeadersPath // empty' <<<"$libs_json")"
  lib="$XCF/$id/$libpath"
  [ -f "$lib" ] || die 1 "$id: library $libpath is missing"
  [ "$(lipo -archs "$lib")" = "arm64" ] || die 1 "$id: the library is not a thin arm64 library"
  if [ -z "$headers" ] || [ -z "$(ls -A "$XCF/$id/$headers" 2>/dev/null)" ]; then
    die 1 "$id: the Headers folder is missing or empty"
  fi
  found="$("$COMMON_SH_DIR/lib-platform.sh" "$lib")" || die 1 "$id: the library does not have a single build platform and minimum OS"
  [ "$found" = "$platform $minos" ] || die 1 "$id: built for '$found', wanted '$platform $minos'"
done

log "ok ($(basename "$XCF"): $*)"
