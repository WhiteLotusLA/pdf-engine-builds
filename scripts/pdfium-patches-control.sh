#!/usr/bin/env bash
# Usage: scripts/pdfium-patches-control.sh
# Control experiment for the patch exporter. It separates "the export is wrong" from "upstream PDFium has moved
# on since the fork was cut":
#   1. checks out the fork's upstream base commit (EMBEDPDF_UPSTREAM_BASE) as a worktree of the clone made by
#      scripts/pdfium-patches-export.sh
#   2. applies patches 0001-0006 of the committed series to it with scripts/pdfium-patches-apply.sh (the Skia patch
#      needs a Skia checkout, so it is left out)
#   3. compares the result with the fork's own tree (EMBEDPDF_COMMIT), file by file, apart from the excluded files
# A correct export applies without a single conflict and reproduces the fork exactly. Exit 0 means it does.
# Exit codes: 0 ok, 1 the series did not apply or the tree differs from the fork, 2 missing input,
# 3 the committed series was exported for different pins.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

require_env EMBEDPDF_COMMIT EMBEDPDF_UPSTREAM_BASE
require_cmd git
RT="$WORK_DIR/embedpdf-runtime"
SERIES="${PATCH_OUT_DIR:-$REPO_ROOT/patches/embedpdf}"
TREE="$WORK_DIR/control-tree"
[ -d "$RT/.git" ] || die 2 "no clone at $RT; run scripts/pdfium-patches-export.sh first"
[ -f "$SERIES/SOURCE.txt" ] || die 2 "no committed series at $SERIES"
grep -qx "source_commit=$EMBEDPDF_COMMIT" "$SERIES/SOURCE.txt" || die 3 "the committed series was exported for a different EMBEDPDF_COMMIT"
grep -qx "upstream_base=$EMBEDPDF_UPSTREAM_BASE" "$SERIES/SOURCE.txt" || die 3 "the committed series was exported for a different EMBEDPDF_UPSTREAM_BASE"

SUBSET="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-patches-control.XXXXXX")"
cleanup() {
  git -C "$RT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
  rm -rf "$SUBSET"
}
trap cleanup EXIT
git -C "$RT" worktree remove --force "$TREE" >/dev/null 2>&1 || true

log "checking out the upstream base $EMBEDPDF_UPSTREAM_BASE (downloads the file contents once, a few hundred MB)"
git -C "$RT" worktree add --detach "$TREE" "$EMBEDPDF_UPSTREAM_BASE" >/dev/null 2>&1 || die 2 "could not check out the upstream base"

mkdir -p "$SUBSET/embedpdf"
cp "$SERIES"/000[1-6]-*.patch "$SUBSET/embedpdf/"
status=0
PDFIUM_DIR="$TREE" PATCH_ROOT="$SUBSET" PATCH_REPORT="$WORK_DIR/control-report.txt" "$REPO_ROOT/scripts/pdfium-patches-apply.sh" || status=1
if [ "$status" -ne 0 ]; then
  die 1 "the series does not apply to its own base; the exporter is wrong (see $WORK_DIR/control-report.txt)"
fi

# Compare with the fork's tree, leaving out the files the series deliberately does not carry.
excludes=()
if [ -s "$SERIES/EXCLUDED.txt" ]; then
  while IFS= read -r f; do
    excludes+=(":(exclude,literal)$f")
  done <"$SERIES/EXCLUDED.txt"
fi
different="$(git -C "$TREE" diff --name-only HEAD "$EMBEDPDF_COMMIT" -- . ${excludes[@]+"${excludes[@]}"})"
if [ -n "$different" ]; then
  echo "$different" | head -20
  die 1 "the patched base differs from the fork in the files listed above"
fi
log "control passed: the series applies to its own base without a conflict and reproduces the fork's tree"
