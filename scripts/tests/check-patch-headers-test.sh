#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/check-patch-headers.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/check-patch-headers.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-patch-headers-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# patch <file> <header lines...>: a patch with the given header lines and a one-file diff
patch() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  {
    local line
    for line in "$@"; do echo "$line"; done
    printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n'
  } >"$file"
}
run() { # <root>: sets $out and $code
  set +e
  out="$("$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}

patch "$WORK/ok/embedpdf/0001-a.patch" "# Source: https://example.invalid/fork" "# License: BSD-3-Clause" "# Apply-Dir: ."
patch "$WORK/ok/embedpdf/0002-b.patch" "# Source: https://example.invalid/fork" "# License: BSD-3-Clause" "# Apply-Dir: third_party/skia"
patch "$WORK/ok/pdfium-binaries/0001-c.patch" "# Source: https://github.com/bblanchon/pdfium-binaries" "# License: MIT"
run "$WORK/ok"
check "patches with source and license headers pass" $([ "$code" -eq 0 ] && grep -q "3 patch file(s) ok" <<<"$out"; echo $?)

patch "$WORK/nosrc/embedpdf/0001.patch" "# License: MIT"
run "$WORK/nosrc"
check "a missing Source line fails" $([ "$code" -eq 1 ] && grep -q "no '# Source:'" <<<"$out"; echo $?)

patch "$WORK/nolic/embedpdf/0001.patch" "# Source: x"
run "$WORK/nolic"
check "a missing License line fails" $([ "$code" -eq 1 ] && grep -q "no '# License:'" <<<"$out"; echo $?)

patch "$WORK/climb/embedpdf/0001.patch" "# Source: x" "# License: y" "# Apply-Dir: ../outside"
run "$WORK/climb"
check "an Apply-Dir that climbs out fails" $([ "$code" -eq 1 ] && grep -q "unsafe Apply-Dir" <<<"$out"; echo $?)

patch "$WORK/abs/embedpdf/0001.patch" "# Source: x" "# License: y" "# Apply-Dir: /etc"
run "$WORK/abs"
check "an absolute Apply-Dir fails" $([ "$code" -eq 1 ] && grep -q "unsafe Apply-Dir" <<<"$out"; echo $?)

mkdir -p "$WORK/nodiff/embedpdf"
printf '# Source: x\n# License: y\n' >"$WORK/nodiff/embedpdf/0001.patch"
run "$WORK/nodiff"
check "a patch with no diff fails" $([ "$code" -eq 1 ] && grep -q "contains no diff" <<<"$out"; echo $?)

mkdir -p "$WORK/empty"
run "$WORK/empty"
check "a root with no patches passes with zero files" $([ "$code" -eq 0 ] && grep -q "0 patch file(s) ok" <<<"$out"; echo $?)

run "$WORK/missing"
check "a missing root is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "check-patch-headers-test: $failures failure(s)"; exit 1; fi
echo "check-patch-headers-test: all passed"
