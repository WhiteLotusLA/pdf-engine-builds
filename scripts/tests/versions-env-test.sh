#!/usr/bin/env bash
# shellcheck disable=SC2046
# Checks versions.env: exactly the contract keys, each with a value of the right shape.
# The values themselves are looked up at pin time (see the "Pins" section of the README).
set -euo pipefail
cd "$(dirname "$0")/../.."
FILE="${VERSIONS_FILE:-$PWD/versions.env}"
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

if [ ! -f "$FILE" ]; then
  echo "FAIL: $FILE does not exist"
  echo "versions-env-test: 1 failure(s)"
  exit 1
fi

get() { sed -n "s/^$1=//p" "$FILE" | head -1; }

EXPECTED_KEYS="PDFIUM_BRANCH EMBEDPDF_REPO EMBEDPDF_COMMIT EMBEDPDF_UPSTREAM_BASE QPDF_VERSION LIBJPEG_TURBO_VERSION MACOS_MIN IOS_MIN DEPOT_TOOLS_COMMIT"
ACTUAL_KEYS="$(grep -E '^[A-Z][A-Z0-9_]*=' "$FILE" | sed 's/=.*//' | sort | tr '\n' ' ' | sed 's/ $//')"
SORTED_EXPECTED="$(echo "$EXPECTED_KEYS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "exactly the nine contract keys, none extra, none missing" $([ "$ACTUAL_KEYS" = "$SORTED_EXPECTED" ]; echo $?)
check "no key appears twice" $([ "$(grep -cE '^[A-Z][A-Z0-9_]*=' "$FILE")" -eq 9 ]; echo $?)
check "no line has spaces around = or is anything but a comment, blank or KEY=VALUE" \
  $([ -z "$(grep -vE '^([A-Z][A-Z0-9_]*=[^[:space:]]+|#.*)$' "$FILE" | grep -v '^$' || true)" ]; echo $?)

match() { # <label> <key> <regex>
  local v
  v="$(get "$2")"
  check "$1 ($2=$v)" $([[ "$v" =~ $3 ]]; echo $?)
}
match "PDFIUM_BRANCH looks like chromium/NNNN" PDFIUM_BRANCH '^chromium/[0-9]{4}$'
match "EMBEDPDF_REPO is the EmbedPDF runtime URL" EMBEDPDF_REPO '^https://github\.com/embedpdf/runtime$'
match "EMBEDPDF_COMMIT is a full SHA" EMBEDPDF_COMMIT '^[0-9a-f]{40}$'
match "EMBEDPDF_UPSTREAM_BASE is a full SHA" EMBEDPDF_UPSTREAM_BASE '^[0-9a-f]{40}$'
match "QPDF_VERSION is a plain version" QPDF_VERSION '^[0-9]+\.[0-9]+\.[0-9]+$'
match "LIBJPEG_TURBO_VERSION is a plain version" LIBJPEG_TURBO_VERSION '^[0-9]+\.[0-9]+(\.[0-9]+)?$'
match "MACOS_MIN is 27.0" MACOS_MIN '^27\.0$'
match "IOS_MIN is 27.0" IOS_MIN '^27\.0$'
match "DEPOT_TOOLS_COMMIT is a full SHA" DEPOT_TOOLS_COMMIT '^[0-9a-f]{40}$'
check "the two EmbedPDF SHAs differ" $([ "$(get EMBEDPDF_COMMIT)" != "$(get EMBEDPDF_UPSTREAM_BASE)" ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "versions-env-test: $failures failure(s)"; exit 1; fi
echo "versions-env-test: all passed"
