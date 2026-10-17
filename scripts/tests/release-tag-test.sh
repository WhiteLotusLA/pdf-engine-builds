#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/release-tag.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/release-tag.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-tag-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

printf 'PDFIUM_BRANCH=chromium/8086\n' >"$WORK/versions.env"
run() { # <tag...>: sets $out and $code
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" VERSIONS_FILE="$WORK/versions.env" "$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}

run v0.0.1-pdfium8086-stock-macos-only
check "the first pre-release tag parses" $([ "$code" -eq 0 ] && grep -qx 'version=0.0.1' <<<"$out" && grep -qx 'pdfium=8086' <<<"$out" && grep -qx 'stock=true' <<<"$out" && grep -qx 'macos_only=true' <<<"$out" && grep -qx 'prerelease=true' <<<"$out"; echo $?)
run v0.1.0-pdfium8086
check "a plain release tag is not a pre-release" $([ "$code" -eq 0 ] && grep -qx 'prerelease=false' <<<"$out" && grep -qx 'stock=false' <<<"$out" && grep -qx 'macos_only=false' <<<"$out"; echo $?)
run v0.2.0-pdfium8086-stock
check "-stock alone is a pre-release" $([ "$code" -eq 0 ] && grep -qx 'prerelease=true' <<<"$out" && grep -qx 'macos_only=false' <<<"$out"; echo $?)
run v0.2.0-pdfium8086-macos-only
check "-macos-only alone is a pre-release" $([ "$code" -eq 0 ] && grep -qx 'prerelease=true' <<<"$out" && grep -qx 'stock=false' <<<"$out"; echo $?)

for bad in "0.0.1-pdfium8086" "v0.0.1" "v0.0-pdfium8086" "v0.0.1-pdfium86" "v0.0.1-pdfium8086-macos-only-stock" "v0.0.1-pdfium8086-beta" "v0.0.1-pdfium8086 " "vX.0.1-pdfium8086" "v0.0.1-pdfium8086-stock;ls"; do
  run "$bad"
  check "malformed tag '$bad' exits 2" $([ "$code" -eq 2 ] && grep -q "does not match" <<<"$out"; echo $?)
done

run v0.0.1-pdfium8087-stock-macos-only
check "a tag that names another PDFium than versions.env exits 3" $([ "$code" -eq 3 ] && grep -q "tag names PDFium 8087 but versions.env pins chromium/8086" <<<"$out"; echo $?)

run
check "no tag is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "release-tag-test: $failures failure(s)"; exit 1; fi
echo "release-tag-test: all passed"
