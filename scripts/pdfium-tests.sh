#!/usr/bin/env bash
# Usage: scripts/pdfium-tests.sh [macos-arm64]
# Builds and runs the EmbedPDF fork's own PDFium tests on a patched tree (run scripts/pdfium-patches-apply.sh first).
#   gate tests (must pass):   unit tests matching *Redact*, *InteractiveForm*, *Signature*  (pdfium_unittests)
#                             EPDFRedactEmbedderTest, EPDFFormEmbedderTest, EPDFSignatureEmbedderTest (pdfium_embeddertests)
#   information (never fails): every other EPDF* embedder test, then the whole of pdfium_unittests
# Results go to dist/test-results/*.json and dist/test-results/summary.txt (names and counts only).
# A gate filter that matches no test, or fewer embedder tests than GATE_EMBEDDER_MIN, is an error: a silent
# filter mistake must never look like a pass.
# Environment (optional): WORK_DIR, DIST_DIR, PDFIUM_DIR, GN_BIN, NINJA_BIN, GATE_EMBEDDER_MIN (default 100).
# Exit codes: 0 gates pass, 1 a gate test failed, 2 usage, 3 the tree is not patched, 4 gn or ninja failed,
#             6 a gate filter matched too few tests.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

SLICE="${1:-macos-arm64}"
[ "$#" -le 1 ] || die 2 "usage: $SCRIPT_NAME [macos-arm64]"
[ "$SLICE" = macos-arm64 ] || die 2 "only macos-arm64 is supported, got '$SLICE'"
require_env MACOS_MIN
GN="${GN_BIN:-gn}"
NINJA="${NINJA_BIN:-ninja}"
PDFIUM_DIR="${PDFIUM_DIR:-$WORK_DIR/pdfium}"
GATE_EMBEDDER_MIN="${GATE_EMBEDDER_MIN:-100}"
if [ -d "$WORK_DIR/depot_tools" ]; then
  export DEPOT_TOOLS_UPDATE=0
  export PATH="$WORK_DIR/depot_tools:$PATH"
fi
[ -f "$PDFIUM_DIR/public/epdf_redact.h" ] || die 3 "the tree at $PDFIUM_DIR is not patched (public/epdf_redact.h missing)"
require_cmd "$GN" "$NINJA" jq

GATE_UNIT='*Redact*:*InteractiveForm*:*Signature*'
GATE_EMBEDDER='EPDFRedactEmbedderTest.*:EPDFFormEmbedderTest.*:EPDFSignatureEmbedderTest.*'

# The out directory must be exactly two levels below the PDFium root: the embedder tests find
# testing/resources relative to the executable (../../testing/resources).
OUT_NAME="$SLICE-tests"
OUT="$PDFIUM_DIR/out/$OUT_NAME"
mkdir -p "$OUT"
{
  echo 'clang_use_chrome_plugins = false'
  echo 'embedpdf_thread_local_globals = false'
  echo 'is_component_build = false'
  echo 'is_debug = true'
  echo "mac_deployment_target = \"$MACOS_MIN\""
  echo "mac_min_system_version = \"$MACOS_MIN\""
  echo 'pdf_enable_v8 = false'
  echo 'pdf_enable_xfa = false'
  echo 'pdf_is_complete_lib = false'
  echo 'pdf_is_standalone = true'
  echo 'pdf_use_partition_alloc = false'
  echo 'pdf_use_skia = false'
  echo 'symbol_level = 1'
  echo 'target_cpu = "arm64"'
  echo 'target_os = "mac"'
  echo 'treat_warnings_as_errors = false'
} | LC_ALL=C sort >"$OUT/args.gn"

log "gn gen out/$OUT_NAME"
(cd "$PDFIUM_DIR" && "$GN" gen "out/$OUT_NAME") || die 4 "gn gen failed"
log "ninja pdfium_unittests pdfium_embeddertests (this takes a long time)"
(cd "$PDFIUM_DIR" && "$NINJA" -C "out/$OUT_NAME" pdfium_unittests pdfium_embeddertests) || die 4 "ninja failed"

RESULTS="$DIST_DIR/test-results"
rm -rf "$RESULTS"
mkdir -p "$RESULTS"
UNIT="$OUT/pdfium_unittests"
EMB="$OUT/pdfium_embeddertests"
[ -x "$UNIT" ] && [ -x "$EMB" ] || die 4 "the test binaries were not built"

# count_tests <binary> <filter>: how many tests the filter selects
count_tests() {
  "$1" --gtest_list_tests --gtest_filter="$2" 2>/dev/null | grep -c '^  ' || true
}

unit_gate_count="$(count_tests "$UNIT" "$GATE_UNIT")"
emb_gate_count="$(count_tests "$EMB" "$GATE_EMBEDDER")"
log "gate tests selected: $unit_gate_count unit, $emb_gate_count embedder"
[ "$unit_gate_count" -ge 1 ] || die 6 "the unit-test gate filter '$GATE_UNIT' matched no test; fix GATE_UNIT in this script after listing the tests"
[ "$emb_gate_count" -ge "$GATE_EMBEDDER_MIN" ] || die 6 "the embedder gate filter matched $emb_gate_count tests, fewer than $GATE_EMBEDDER_MIN"

# run_gtest <label> <binary> <filter>: JSON report in $RESULTS/<label>.json; returns the binary's exit status
run_gtest() {
  local rc=0
  "$2" --gtest_filter="$3" --gtest_output="json:$RESULTS/$1.json" >"$RESULTS/$1.log" 2>&1 || rc=$?
  return "$rc"
}

gate_fail=0
run_gtest gate-unit "$UNIT" "$GATE_UNIT" || gate_fail=1
run_gtest gate-embedder "$EMB" "$GATE_EMBEDDER" || gate_fail=1
run_gtest info-embedder "$EMB" 'EPDF*' || true
run_gtest info-unit "$UNIT" '*' || true

# summarize <label>: "label: N tests, M failed" and the failing test names
summarize() {
  local f="$RESULTS/$1.json"
  if [ ! -f "$f" ]; then
    echo "$1: no result file (the test binary crashed before writing one)"
    return
  fi
  echo "$1: $(jq -r '"\(.tests) tests, \(.failures) failed, \(.disabled) disabled"' "$f")"
  jq -r '.testsuites[] | .name as $s | .testsuite[] | select(has("failures")) | "  FAILED \($s).\(.name)"' "$f"
}
{
  echo "pdfium-tests summary (PDFium $PDFIUM_BRANCH, EmbedPDF ${EMBEDPDF_COMMIT:-unknown})"
  summarize gate-unit
  summarize gate-embedder
  summarize info-embedder
  summarize info-unit
} >"$RESULTS/summary.txt"
cat "$RESULTS/summary.txt"

for gate in gate-unit gate-embedder; do
  [ -f "$RESULTS/$gate.json" ] || gate_fail=1
done
if [ "$gate_fail" -ne 0 ]; then
  die 1 "a gate test failed (see $RESULTS/summary.txt)"
fi
log "gate tests passed"
