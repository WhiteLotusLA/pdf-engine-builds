#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-tests.sh with fake gn, ninja and gtest binaries (nothing is compiled).
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-tests.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-tests-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gn" <<'FAKE'
#!/usr/bin/env bash
echo "gn $*" >>"$FAKE_LOG"
[ "${FAKE_GN_FAIL:-0}" = "1" ] && exit 1
exit 0
FAKE
# The fake ninja writes two fake gtest binaries into the out directory (-C <dir>).
cat >"$WORK/bin/ninja" <<'FAKE'
#!/usr/bin/env bash
echo "ninja $*" >>"$FAKE_LOG"
[ "${FAKE_NINJA_FAIL:-0}" = "1" ] && exit 1
for name in pdfium_unittests pdfium_embeddertests; do
  cp "$FAKE_GTEST" "$2/$name"
  chmod +x "$2/$name"
done
exit 0
FAKE
cat >"$WORK/bin/fake-gtest" <<'FAKE'
#!/usr/bin/env bash
# Fake gtest binary. Behaviour comes from FAKE_* variables.
filter="" output="" list=0
for a in "$@"; do
  case "$a" in
    --gtest_list_tests) list=1 ;;
    --gtest_filter=*) filter="${a#--gtest_filter=}" ;;
    --gtest_output=json:*) output="${a#--gtest_output=json:}" ;;
  esac
done
name="$(basename "$0")"
is_gate=0
case "$filter" in
  *Redact*) is_gate=1 ;;
esac
if [ "$list" = "1" ]; then
  [ "${FAKE_ZERO:-0}" = "1" ] && exit 0
  count=3
  if [ "$name" = "pdfium_embeddertests" ] && [ "$is_gate" = "1" ]; then count="${FAKE_EMB_COUNT:-111}"; fi
  echo "Suite."
  i=0
  while [ "$i" -lt "$count" ]; do echo "  Test$i"; i=$((i + 1)); done
  exit 0
fi
if [ "${FAKE_GATE_FAIL:-0}" = "1" ] && [ "$is_gate" = "1" ] && [ "$name" = "pdfium_embeddertests" ]; then
  printf '{"tests":2,"failures":1,"disabled":0,"errors":0,"testsuites":[{"name":"EPDFRedactEmbedderTest","testsuite":[{"name":"Broken","failures":[{"failure":"x"}]},{"name":"Fine"}]}]}\n' >"$output"
  exit 1
fi
if [ "${FAKE_INFO_FAIL:-0}" = "1" ] && [ "$is_gate" = "0" ] && [ "$name" = "pdfium_embeddertests" ]; then
  printf '{"tests":2,"failures":1,"disabled":0,"errors":0,"testsuites":[{"name":"EPDFMeasureEmbedderTest","testsuite":[{"name":"Odd","failures":[{"failure":"x"}]},{"name":"Fine"}]}]}\n' >"$output"
  exit 1
fi
printf '{"tests":2,"failures":0,"disabled":0,"errors":0,"testsuites":[{"name":"S","testsuite":[{"name":"A"},{"name":"B"}]}]}\n' >"$output"
exit 0
FAKE
chmod +x "$WORK/bin/gn" "$WORK/bin/ninja" "$WORK/bin/fake-gtest"

printf 'PDFIUM_BRANCH=chromium/8086\nMACOS_MIN=27.0\nEMBEDPDF_COMMIT=1111111111111111111111111111111111111111\n' >"$WORK/versions.env"

patched_tree() { # <yes|no>
  rm -rf "$WORK/w"
  mkdir -p "$WORK/w/pdfium/public"
  [ "$1" != yes ] || : >"$WORK/w/pdfium/public/epdf_redact.h"
}

run() { # <env assignments...>: sets $out and $code
  : >"$WORK/log"
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" WORK_DIR="$WORK/w" DIST_DIR="$WORK/w/dist" VERSIONS_FILE="$WORK/versions.env" \
    GN_BIN="$WORK/bin/gn" NINJA_BIN="$WORK/bin/ninja" FAKE_GTEST="$WORK/bin/fake-gtest" FAKE_LOG="$WORK/log" \
    ${1:+"$@"} "$SCRIPT" 2>&1)"
  code=$?
  set -e
}
ARGS="$WORK/w/pdfium/out/macos-arm64-tests/args.gn"

patched_tree no
run
check "an unpatched tree exits 3 and builds nothing" $([ "$code" -eq 3 ] && [ ! -s "$WORK/log" ]; echo $?)

patched_tree yes
run
check "all gates passing exits 0" $([ "$code" -eq 0 ] && grep -q "gate tests passed" <<<"$out"; echo $?)
check "the test build is a debug, non-complete-lib build declared for the fork" \
  $(grep -qx 'is_debug = true' "$ARGS" && grep -qx 'pdf_is_complete_lib = false' "$ARGS" && grep -qx 'embedpdf_thread_local_globals = false' "$ARGS" && grep -qx 'mac_deployment_target = "27.0"' "$ARGS"; echo $?)
check "ninja builds both test targets in out/macos-arm64-tests (two levels below the root)" $(grep -q 'ninja -C out/macos-arm64-tests pdfium_unittests pdfium_embeddertests' "$WORK/log"; echo $?)
check "summary.txt lists the four result sets" $([ "$(grep -cE '^(gate-unit|gate-embedder|info-embedder|info-unit):' "$WORK/w/dist/test-results/summary.txt")" -eq 4 ]; echo $?)

run FAKE_GATE_FAIL=1
check "a failing gate test exits 1 and names the test" $([ "$code" -eq 1 ] && grep -q "FAILED EPDFRedactEmbedderTest.Broken" <<<"$out"; echo $?)

run FAKE_INFO_FAIL=1
check "a failing information test is reported but does not fail the run" $([ "$code" -eq 0 ] && grep -q "FAILED EPDFMeasureEmbedderTest.Odd" <<<"$out"; echo $?)

run FAKE_ZERO=1
check "a gate filter that matches nothing exits 6" $([ "$code" -eq 6 ] && grep -q "matched no test" <<<"$out"; echo $?)

run FAKE_EMB_COUNT=40
check "an embedder gate that shrank below the minimum exits 6" $([ "$code" -eq 6 ] && grep -q "fewer than 100" <<<"$out"; echo $?)
run FAKE_NINJA_FAIL=1
check "a ninja failure exits 4" $([ "$code" -eq 4 ] && grep -q "ninja failed" <<<"$out"; echo $?)
run FAKE_GN_FAIL=1
check "a gn failure exits 4" $([ "$code" -eq 4 ] && grep -q "gn gen failed" <<<"$out"; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-tests-test: $failures failure(s)"; exit 1; fi
echo "pdfium-tests-test: all passed"
