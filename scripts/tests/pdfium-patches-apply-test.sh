#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-patches-apply.sh on a fake PDFium checkout (a git repo with a nested "skia" repo).
# Review focus: a patch that does not apply cleanly fails the run, produces the conflict report, and never leaves
# a partial patch set behind.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-patches-apply.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-patches-apply-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
g() { git -c commit.gpgsign=false "$@"; }
lines() { # <prefix> <count>
  local i=1
  while [ "$i" -le "$2" ]; do echo "$1 $i"; i=$((i + 1)); done
}

PD="$WORK/w/pdfium"
SK="$PD/third_party/skia"
PATCHES="$WORK/patches"

# mk_checkout: a fresh fake checkout; mk_patches: the three patches made from it
mk_checkout() {
  rm -rf "$WORK/w"
  mkdir -p "$SK"
  g -C "$PD" init -q -b main
  lines pdfium 30 >"$PD/a.txt"
  lines pdfium 30 >"$PD/c.txt"
  lines pdfium 30 >"$PD/d.txt"
  printf 'third_party/skia/\nout/\n' >"$PD/.gitignore"
  g -C "$PD" add -A
  g -C "$PD" commit -q -m base
  g -C "$SK" init -q -b main
  lines skia 10 >"$SK/src.txt"
  g -C "$SK" add -A
  g -C "$SK" commit -q -m base
  echo "abc123" >"$WORK/w/pdfium-head.txt"
}
header() { # <apply dir>
  printf '# Source: https://example.invalid/fork\n# License: BSD-3-Clause\n# Apply-Dir: %s\n#\n' "$1"
}
mk_patches() {
  rm -rf "$PATCHES"
  mkdir -p "$PATCHES/embedpdf" "$PATCHES/pdfium-binaries"
  # 0001: two hunks in a.txt, far apart
  sed -i.bak '5s/.*/changed five/; 25s/.*/changed twenty-five/' "$PD/a.txt" && rm "$PD/a.txt.bak"
  { header .; g -C "$PD" diff --full-index; } >"$PATCHES/embedpdf/0001-a.patch"
  g -C "$PD" checkout -q -- a.txt
  # 0002: a new file and a change to c.txt
  mkdir -p "$PD/new"
  echo "brand new" >"$PD/new/b.txt"
  sed -i.bak '3s/.*/changed three/' "$PD/c.txt" && rm "$PD/c.txt.bak"
  g -C "$PD" add -N new/b.txt
  { header .; g -C "$PD" diff --full-index; } >"$PATCHES/embedpdf/0002-b.patch"
  g -C "$PD" checkout -q -- c.txt
  g -C "$PD" reset -q -- new/b.txt
  rm -rf "$PD/new"
  # 0003: a change inside the nested skia checkout
  sed -i.bak '2s/.*/changed skia two/' "$SK/src.txt" && rm "$SK/src.txt.bak"
  { header third_party/skia; g -C "$SK" diff --full-index; } >"$PATCHES/embedpdf/0003-skia.patch"
  g -C "$SK" checkout -q -- src.txt
}

run() { # <env assignments...>: sets $out and $code
  set +e
  out="$(env -i PATH="$PATH" HOME="$WORK" TMPDIR="$WORK" WORK_DIR="$WORK/w" DIST_DIR="$WORK/w/dist" PDFIUM_DIR="$PD" \
    PATCH_ROOT="$PATCHES" VERSIONS_FILE="$WORK/versions.env" ${1:+"$@"} "$SCRIPT" 2>&1)"
  code=$?
  set -e
}
printf 'PDFIUM_BRANCH=chromium/8086\nEMBEDPDF_COMMIT=1111111111111111111111111111111111111111\nEMBEDPDF_UPSTREAM_BASE=2222222222222222222222222222222222222222\n' >"$WORK/versions.env"
REPORT="$WORK/w/dist/patch-report.txt"

# --- clean apply -----------------------------------------------------------------------------------------------
mk_checkout
mk_patches
run
check "a clean series applies (exit 0)" $([ "$code" -eq 0 ]; echo $?)
check "the changes are in the tree" $(sed -n 5p "$PD/a.txt" | grep -q "changed five" && grep -q "brand new" "$PD/new/b.txt" && sed -n 3p "$PD/c.txt" | grep -q "changed three"; echo $?)
check "the nested skia checkout got its patch" $(sed -n 2p "$SK/src.txt" | grep -q "changed skia two"; echo $?)
check "the report says PASS with 3 patches applied and none conflicted" \
  $(grep -qx 'result: PASS' "$REPORT" && grep -qx 'patches: 3' "$REPORT" && grep -qx 'applied: 3' "$REPORT" && grep -qx 'conflicted: 0' "$REPORT" && grep -qx 'files_changed: 4' "$REPORT"; echo $?)
check "the report carries the pins" $(grep -qx 'pdfium_branch: chromium/8086' "$REPORT" && grep -q '^embedpdf_commit: 1111' "$REPORT" && grep -q '^pdfium_head: abc123' "$REPORT"; echo $?)
check "the report lists each applied patch" $(grep -q '^APPLIED  0001-a.patch' "$REPORT" && grep -q '^APPLIED  0003-skia.patch (1 files, apply dir third_party/skia)' "$REPORT"; echo $?)

# --- a conflict in the middle of the series ------------------------------------------------------------------
mk_checkout
mk_patches
# upstream moved: lines 4 to 6 of a.txt changed, so the first hunk of 0001 cannot apply; the second still could
sed -i.bak '4s/.*/upstream edit four/; 6s/.*/upstream edit six/' "$PD/a.txt" && rm "$PD/a.txt.bak"
g -C "$PD" commit -q -am "upstream moved"
START_PD="$(g -C "$PD" rev-parse HEAD)"
START_SK="$(g -C "$SK" rev-parse HEAD)"
run
check "a conflicting patch makes the run fail (exit 1)" $([ "$code" -eq 1 ] && grep -q "1 of 3 patch(es) conflicted" <<<"$out"; echo $?)
check "the report says FAIL, names the patch, the file and the rejected hunk" \
  $(grep -qx 'result: FAIL' "$REPORT" && grep -q '^CONFLICT 0001-a.patch' "$REPORT" && grep -q 'rejected hunks: a.txt (1)' "$REPORT" && grep -qx 'conflicted: 1' "$REPORT" && grep -qx 'hunks_rejected: 1' "$REPORT"; echo $?)
check "the patches that applied cleanly are listed as such in the report" $(grep -q '^APPLIED  0002-b.patch' "$REPORT" && grep -q '^APPLIED  0003-skia.patch' "$REPORT"; echo $?)
check "NO partial patch set: the main checkout is back at its start commit with a clean tree" \
  $([ "$(g -C "$PD" rev-parse HEAD)" = "$START_PD" ] && [ -z "$(g -C "$PD" status --porcelain)" ] && [ ! -e "$PD/new/b.txt" ] && ! grep -q "changed three" "$PD/c.txt" && ! grep -q "changed five" "$PD/a.txt" && [ ! -e "$PD/a.txt.rej" ]; echo $?)
check "NO partial patch set: the nested skia checkout is back at its start commit with a clean tree" \
  $([ "$(g -C "$SK" rev-parse HEAD)" = "$START_SK" ] && [ -z "$(g -C "$SK" status --porcelain)" ] && ! grep -q "changed skia" "$SK/src.txt"; echo $?)

# --- a patch for a file this PDFium does not have ------------------------------------------------------------
mk_checkout
mk_patches
g -C "$PD" rm -q d.txt
g -C "$PD" commit -q -m "upstream removed d.txt"
sed -i.bak 's#^diff --git a/c.txt b/c.txt#diff --git a/d.txt b/d.txt#; s#^--- a/c.txt#--- a/d.txt#; s#^+++ b/c.txt#+++ b/d.txt#' "$PATCHES/embedpdf/0002-b.patch" && rm "$PATCHES/embedpdf/0002-b.patch.bak"
run
check "a patch for a vanished file conflicts and says so" $([ "$code" -eq 1 ] && grep -q 'file does not exist in this PDFium: d.txt' "$REPORT"; echo $?)
check "a brand new file from the failed patch was removed again" $([ ! -e "$PD/new/b.txt" ]; echo $?)

# --- a patch that is already in the tree ---------------------------------------------------------------------
mk_checkout
mk_patches
run
run
check "applying the series twice is refused up front or conflicts, never silently doubled" \
  $([ "$code" -eq 1 ] || [ "$code" -eq 4 ]; echo $?)

# --- Apply-Dir problems --------------------------------------------------------------------------------------
mk_checkout
mk_patches
sed -i.bak 's#^\# Apply-Dir: third_party/skia#\# Apply-Dir: ../escape#' "$PATCHES/embedpdf/0003-skia.patch" && rm "$PATCHES/embedpdf/0003-skia.patch.bak"
run
check "an Apply-Dir that climbs out of the checkout exits 2 before anything is applied" \
  $([ "$code" -eq 2 ] && grep -q "unsafe Apply-Dir" <<<"$out" && [ -z "$(g -C "$PD" status --porcelain)" ] && ! grep -q "changed five" "$PD/a.txt"; echo $?)
mk_checkout
mk_patches
sed -i.bak 's#^\# Apply-Dir: third_party/skia#\# Apply-Dir: third_party/not-there#' "$PATCHES/embedpdf/0003-skia.patch" && rm "$PATCHES/embedpdf/0003-skia.patch.bak"
run
check "an Apply-Dir that is not a git checkout is a conflict" $([ "$code" -eq 1 ] && grep -q "apply dir is not a git checkout" "$REPORT"; echo $?)

# --- an unexpected failure part-way through also leaves nothing behind -------------------------------------------
mk_checkout
mk_patches
START_PD="$(g -C "$PD" rev-parse HEAD)"
mkdir -p "$PD/.git/hooks"
printf '#!/bin/sh\nexit 1\n' >"$PD/.git/hooks/pre-commit"
chmod +x "$PD/.git/hooks/pre-commit"
run
check "when the scratch commit itself fails, the run fails and the checkout is restored" \
  $([ "$code" -ne 0 ] && [ "$(g -C "$PD" rev-parse HEAD)" = "$START_PD" ] && [ -z "$(g -C "$PD" status --porcelain)" ] && ! grep -q "changed five" "$PD/a.txt"; echo $?)

# --- preconditions -------------------------------------------------------------------------------------------------
mk_checkout
mk_patches
echo "local edit" >>"$PD/d.txt"
run
check "a checkout with local changes exits 4" $([ "$code" -eq 4 ] && grep -q "local changes" <<<"$out"; echo $?)
mk_checkout
mk_patches
mkdir -p "$PD/public"
: >"$PD/public/epdf_redact.h"
run
check "an already patched checkout exits 4" $([ "$code" -eq 4 ] && grep -q "already has the EmbedPDF files" <<<"$out"; echo $?)
mk_checkout
rm -rf "$PATCHES"
mkdir -p "$PATCHES/embedpdf"
run
check "no patch files exits 4" $([ "$code" -eq 4 ] && grep -q "no patch files found" <<<"$out"; echo $?)
rm -rf "$WORK/w"
run
check "no checkout exits 4" $([ "$code" -eq 4 ] && grep -q "pdfium-checkout.sh" <<<"$out"; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-patches-apply-test: $failures failure(s)"; exit 1; fi
echo "pdfium-patches-apply-test: all passed"
