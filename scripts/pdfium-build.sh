#!/usr/bin/env bash
# Usage: scripts/pdfium-build.sh <slice> [--embedpdf]
#   slice:      macos-arm64 (the iOS slices ios-arm64 and iossim-arm64 are added by plan task A4)
#   --embedpdf: the tree has the EmbedPDF patch series applied (scripts/pdfium-patches-apply.sh)
# Builds the complete static library with gn and ninja and copies it to dist/slices/<slice>/libpdfium.a
# together with the args.gn that produced it and a BUILD-INFO.txt. A stock build refuses a patched tree and
# a patched build refuses a stock tree, so a release can never carry the wrong label.
# Environment (optional): WORK_DIR, DIST_DIR, PDFIUM_DIR (default $WORK_DIR/pdfium), GN_BIN, NINJA_BIN.
# Exit codes: 0 ok, 2 usage, 3 the tree does not match the mode, 4 gn or ninja failed, 5 the library is missing.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

usage() { die 2 "usage: $SCRIPT_NAME <macos-arm64> [--embedpdf]"; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
SLICE="$1"
MODE=stock
case "${2:-}" in
  '') ;;
  --embedpdf) MODE=embedpdf ;;
  *) usage ;;
esac

require_env MACOS_MIN IOS_MIN PDFIUM_BRANCH
GN="${GN_BIN:-gn}"
NINJA="${NINJA_BIN:-ninja}"
PDFIUM_DIR="${PDFIUM_DIR:-$WORK_DIR/pdfium}"
if [ -d "$WORK_DIR/depot_tools" ]; then
  export DEPOT_TOOLS_UPDATE=0
  export PATH="$WORK_DIR/depot_tools:$PATH"
fi

case "$SLICE" in
  macos-arm64)
    GN_OS=mac
    GN_CPU=arm64
    ;;
  ios-arm64 | iossim-arm64)
    die 2 "slice $SLICE is added by plan task A4 (iOS slices); only macos-arm64 is supported here"
    ;;
  *) usage ;;
esac

[ -f "$PDFIUM_DIR/BUILD.gn" ] || die 3 "no PDFium checkout at $PDFIUM_DIR (run scripts/pdfium-checkout.sh first)"
if [ "$MODE" = embedpdf ]; then
  [ -f "$PDFIUM_DIR/public/epdf_redact.h" ] || die 3 "--embedpdf needs the patch series applied, but public/epdf_redact.h is missing (run scripts/pdfium-patches-apply.sh)"
else
  [ ! -e "$PDFIUM_DIR/public/epdf_redact.h" ] || die 3 "this tree has EmbedPDF files; a stock build must use an unpatched checkout (or pass --embedpdf)"
fi
require_cmd "$GN" "$NINJA"

OUT="$PDFIUM_DIR/out/$SLICE"
mkdir -p "$OUT"
{
  echo 'clang_use_chrome_plugins = false'
  echo 'is_component_build = false'
  echo 'is_debug = false'
  echo "mac_deployment_target = \"$MACOS_MIN\""
  echo "mac_min_system_version = \"$MACOS_MIN\""
  echo 'pdf_enable_v8 = false'
  echo 'pdf_enable_xfa = false'
  echo 'pdf_is_complete_lib = true'
  echo 'pdf_is_standalone = true'
  echo 'pdf_use_partition_alloc = false'
  echo 'symbol_level = 0'
  echo "target_cpu = \"$GN_CPU\""
  echo "target_os = \"$GN_OS\""
  echo 'treat_warnings_as_errors = false'
  # Static library for an app: use the system libc++ (Chromium's own libc++ is not linked into a static lib).
  echo 'use_custom_libcxx = false'
  if [ "$MODE" = embedpdf ]; then
    # Declared by the EmbedPDF patch series. Off: one engine thread per process in our design.
    echo 'embedpdf_thread_local_globals = false'
  fi
} | LC_ALL=C sort >"$OUT/args.gn"

log "gn gen out/$SLICE ($MODE)"
(cd "$PDFIUM_DIR" && "$GN" gen "out/$SLICE") || die 4 "gn gen failed"
log "ninja -C out/$SLICE pdfium"
(cd "$PDFIUM_DIR" && "$NINJA" -C "out/$SLICE" pdfium) || die 4 "ninja failed"

# The stock library is obj/libpdfium.a. The EmbedPDF patches rename the GN output to libembedpdf.a.
LIB=""
if [ "$MODE" = stock ]; then
  [ -f "$OUT/obj/libpdfium.a" ] || die 5 "expected $OUT/obj/libpdfium.a after the build"
  LIB="$OUT/obj/libpdfium.a"
else
  for candidate in libembedpdf.a libpdfium.a; do
    if [ -f "$OUT/obj/$candidate" ]; then
      LIB="$OUT/obj/$candidate"
      break
    fi
  done
  [ -n "$LIB" ] || die 5 "expected $OUT/obj/libembedpdf.a or libpdfium.a after the build"
fi

DEST="$DIST_DIR/slices/$SLICE"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$LIB" "$DEST/libpdfium.a"
cp "$OUT/args.gn" "$DEST/args.gn"

head_sha="unknown"
if [ -f "$WORK_DIR/pdfium-head.txt" ]; then
  head_sha="$(cat "$WORK_DIR/pdfium-head.txt")"
fi
{
  echo "slice=$SLICE"
  echo "mode=$MODE"
  echo "pdfium_branch=$PDFIUM_BRANCH"
  echo "pdfium_head=$head_sha"
  if [ "$MODE" = embedpdf ]; then
    echo "embedpdf_commit=${EMBEDPDF_COMMIT:-unknown}"
    echo "embedpdf_upstream_base=${EMBEDPDF_UPSTREAM_BASE:-unknown}"
  fi
  echo "macos_min=$MACOS_MIN"
  echo "xcode=$( (xcodebuild -version 2>/dev/null || echo unknown) | head -1 | tr ' ' '_')"
} >"$DEST/BUILD-INFO.txt"

log "wrote $DEST/libpdfium.a ($(wc -c <"$DEST/libpdfium.a" | tr -d ' ') bytes)"
