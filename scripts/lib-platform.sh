#!/usr/bin/env bash
# Usage: scripts/lib-platform.sh <static library or Mach-O file>
#
# Prints "<PLATFORM> <minimum OS>" for a thin Apple library, for example "IOSSIMULATOR 27.0".
# PLATFORM is the name otool prints for the LC_BUILD_VERSION load command: MACOS, IOS or
# IOSSIMULATOR (and others). Every object in the library must agree; a library that mixes
# platforms or minimum OS versions, or has no build version at all, fails.
# Exit codes: 0 ok, 1 mixed or missing build version, 2 usage or tool missing.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -eq 1 ] && [ -f "$1" ] || die 2 "usage: lib-platform.sh <library file>"
require_cmd otool

# otool fails on a file that is not Mach-O; that must reach the "missing" message below, not end the script early.
info="$({ otool -lv "$1" 2>/dev/null || true; } | awk '/^ *platform /{p[$2]=1} /^ *minos /{m[$2]=1} END{for(k in p) print "platform " k; for(k in m) print "minos " k}' | LC_ALL=C sort)"
platforms="$(sed -n 's/^platform //p' <<<"$info")"
versions="$(sed -n 's/^minos //p' <<<"$info")"
if [ -z "$platforms" ] || [ -z "$versions" ] || [ "$(wc -l <<<"$platforms" | tr -d ' ')" -ne 1 ] || [ "$(wc -l <<<"$versions" | tr -d ' ')" -ne 1 ]; then
  die 1 "$(basename "$1"): expected one platform and one minimum OS, found: $(tr '\n' ' ' <<<"$info")"
fi
printf '%s %s\n' "$platforms" "$versions"
