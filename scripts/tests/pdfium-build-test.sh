#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-build.sh with a fake gn and a fake ninja (nothing is compiled).
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-build.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-build-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gn" <<'FAKE'
#!/usr/bin/env bash
echo "gn $* (cwd $(basename "$PWD"))" >>"$FAKE_LOG"
[ "${FAKE_GN_FAIL:-0}" = "1" ] && exit 1
[ -f "$2/args.gn" ] || { echo "args.gn missing in $2" >&2; exit 1; }
exit 0
FAKE
cat >"$WORK/bin/ninja" <<'FAKE'
#!/usr/bin/env bash
echo "ninja $* (cwd $(basename "$PWD"))" >>"$FAKE_LOG"
[ "${FAKE_NINJA_FAIL:-0}" = "1" ] && exit 1
mkdir -p "$2/obj"
[ -n "${FAKE_LIB:-}" ] && echo "fake archive" >"$2/obj/$FAKE_LIB"
exit 0
FAKE
chmod +x "$WORK/bin/gn" "$WORK/bin/ninja"

cat >"$WORK/versions.env" <<'EOF'
PDFIUM_BRANCH=chromium/8086
EMBEDPDF_COMMIT=1111111111111111111111111111111111111111
EMBEDPDF_UPSTREAM_BASE=2222222222222222222222222222222222222222
MACOS_MIN=27.0
IOS_MIN=27.0
EOF

# tree <patched yes|no>: a fake PDFium checkout in $WORK/w/pdfium
tree() {
  rm -rf "$WORK/w"
  mkdir -p "$WORK/w/pdfium/public"
  : >"$WORK/w/pdfium/BUILD.gn"
  echo "abcabcabcabcabcabcabcabcabcabcabcabcabca" >"$WORK/w/pdfium-head.txt"
  if [ "$1" = yes ]; then : >"$WORK/w/pdfium/public/epdf_redact.h"; fi
}

# run <args...> -- <env assignments...>: sets $out and $code
run() {
  local args=() envs=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; elif [ "$seen" -eq 0 ]; then args+=("$a"); else envs+=("$a"); fi
  done
  : >"$WORK/log"
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" WORK_DIR="$WORK/w" DIST_DIR="$WORK/w/dist" VERSIONS_FILE="$WORK/versions.env" \
    GN_BIN="$WORK/bin/gn" NINJA_BIN="$WORK/bin/ninja" FAKE_LOG="$WORK/log" ${envs[@]+"${envs[@]}"} "$SCRIPT" ${args[@]+"${args[@]}"} 2>&1)"
  code=$?
  set -e
}
ARGS="$WORK/w/pdfium/out/macos-arm64/args.gn"

# --- stock build ---
tree no
run macos-arm64 -- FAKE_LIB=libpdfium.a
check "stock build exits 0" $([ "$code" -eq 0 ]; echo $?)
check "args.gn asks for the complete static library" $(grep -qx 'pdf_is_complete_lib = true' "$ARGS"; echo $?)
check "args.gn sets the deployment target from MACOS_MIN" $(grep -qx 'mac_deployment_target = "27.0"' "$ARGS" && grep -qx 'mac_min_system_version = "27.0"' "$ARGS"; echo $?)
check "args.gn turns off V8, XFA, partition alloc, the custom libc++ and warnings-as-errors" \
  $(grep -qx 'pdf_enable_v8 = false' "$ARGS" && grep -qx 'pdf_enable_xfa = false' "$ARGS" && grep -qx 'pdf_use_partition_alloc = false' "$ARGS" && grep -qx 'use_custom_libcxx = false' "$ARGS" && grep -qx 'treat_warnings_as_errors = false' "$ARGS"; echo $?)
check "args.gn targets mac arm64 and is a release build" $(grep -qx 'target_os = "mac"' "$ARGS" && grep -qx 'target_cpu = "arm64"' "$ARGS" && grep -qx 'is_debug = false' "$ARGS"; echo $?)
check "a stock build does not mention the EmbedPDF GN argument" $(! grep -q embedpdf "$ARGS"; echo $?)
check "args.gn is sorted" $([ "$(LC_ALL=C sort "$ARGS")" = "$(cat "$ARGS")" ]; echo $?)
check "gn gen and ninja ran in the pdfium directory, ninja building the pdfium target" \
  $(grep -q 'gn gen out/macos-arm64 (cwd pdfium)' "$WORK/log" && grep -q 'ninja -C out/macos-arm64 pdfium (cwd pdfium)' "$WORK/log"; echo $?)
check "the library is copied to dist/slices/macos-arm64/libpdfium.a with args.gn and BUILD-INFO.txt" \
  $([ -f "$WORK/w/dist/slices/macos-arm64/libpdfium.a" ] && [ -f "$WORK/w/dist/slices/macos-arm64/args.gn" ] && [ -f "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt" ]; echo $?)
check "BUILD-INFO.txt records mode, branch and the PDFium commit" \
  $(grep -qx 'mode=stock' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt" && grep -qx 'pdfium_branch=chromium/8086' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt" && grep -q '^pdfium_head=abcabc' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt"; echo $?)

# --- stock mode is strict about the tree and the library name ---
tree yes
run macos-arm64 -- FAKE_LIB=libpdfium.a
check "a stock build refuses a tree that has EmbedPDF files (exit 3)" $([ "$code" -eq 3 ] && grep -q "stock build must use an unpatched checkout" <<<"$out" && [ ! -s "$WORK/log" ]; echo $?)
tree no
run macos-arm64 -- FAKE_LIB=libembedpdf.a
check "a stock build that produced only libembedpdf.a exits 5" $([ "$code" -eq 5 ]; echo $?)

# --- patched build ---
tree yes
run macos-arm64 --embedpdf -- FAKE_LIB=libembedpdf.a
check "patched build exits 0" $([ "$code" -eq 0 ]; echo $?)
check "patched args.gn declares embedpdf_thread_local_globals = false" $(grep -qx 'embedpdf_thread_local_globals = false' "$ARGS"; echo $?)
check "libembedpdf.a is installed under the stable name libpdfium.a" $([ -f "$WORK/w/dist/slices/macos-arm64/libpdfium.a" ]; echo $?)
check "BUILD-INFO.txt of a patched build records both EmbedPDF SHAs" \
  $(grep -qx 'mode=embedpdf' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt" && grep -q '^embedpdf_commit=1111' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt" && grep -q '^embedpdf_upstream_base=2222' "$WORK/w/dist/slices/macos-arm64/BUILD-INFO.txt"; echo $?)
tree no
run macos-arm64 --embedpdf -- FAKE_LIB=libpdfium.a
check "a patched build refuses an unpatched tree (exit 3)" $([ "$code" -eq 3 ] && grep -q "needs the patch series applied" <<<"$out"; echo $?)

# --- usage and failures ---
tree no
run -- FAKE_LIB=libpdfium.a
check "no slice is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)
run ios-arm64 -- FAKE_LIB=libpdfium.a
check "ios-arm64 exits 2 and points at task A4" $([ "$code" -eq 2 ] && grep -q "task A4" <<<"$out"; echo $?)
run iossim-arm64 -- FAKE_LIB=libpdfium.a
check "iossim-arm64 exits 2 and points at task A4" $([ "$code" -eq 2 ] && grep -q "task A4" <<<"$out"; echo $?)
run linux-x64 -- FAKE_LIB=libpdfium.a
check "an unknown slice is a usage error" $([ "$code" -eq 2 ]; echo $?)
run macos-arm64 --bogus -- FAKE_LIB=libpdfium.a
check "an unknown flag is a usage error" $([ "$code" -eq 2 ]; echo $?)
run macos-arm64 -- FAKE_LIB=libpdfium.a FAKE_GN_FAIL=1
check "gn failure exits 4" $([ "$code" -eq 4 ] && grep -q "gn gen failed" <<<"$out"; echo $?)
run macos-arm64 -- FAKE_LIB=libpdfium.a FAKE_NINJA_FAIL=1
check "ninja failure exits 4" $([ "$code" -eq 4 ] && grep -q "ninja failed" <<<"$out"; echo $?)
rm -rf "$WORK/w/pdfium"
run macos-arm64 -- FAKE_LIB=libpdfium.a
check "a missing checkout exits 3 and says which script to run" $([ "$code" -eq 3 ] && grep -q "pdfium-checkout.sh" <<<"$out"; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-build-test: $failures failure(s)"; exit 1; fi
echo "pdfium-build-test: all passed"
