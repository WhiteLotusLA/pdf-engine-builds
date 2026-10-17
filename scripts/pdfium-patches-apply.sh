#!/usr/bin/env bash
# Usage: scripts/pdfium-patches-apply.sh
# Applies patches/pdfium-binaries/*.patch and then patches/embedpdf/*.patch (each directory in file-name order)
# onto the PDFium checkout at $PDFIUM_DIR (default work/pdfium). Each patch file names the git checkout it applies
# to in a header line "# Apply-Dir: <dir>" (default "."; the Skia patch uses third_party/skia).
#
# All or nothing. Every patch is tried even after a conflict, so the report shows every conflict at once. If any patch
# conflicts, the whole series is rolled back (the checkout ends exactly as it started) and the script exits 1.
# The report is written either way, to dist/patch-report.txt: patch counts, which patches applied, and for each
# conflict the files and the number of rejected hunks. The report holds file names and counts only.
#
# Environment (optional): WORK_DIR, DIST_DIR, PDFIUM_DIR, PATCH_ROOT (default <repo>/patches), PATCH_REPORT.
# Exit codes: 0 all applied, 1 at least one patch conflicted (nothing applied, report written), 2 usage or missing
# tool, 4 the checkout is not in the state the script needs.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

[ "$#" -eq 0 ] || die 2 "usage: $SCRIPT_NAME"
require_cmd git
PDFIUM_DIR="${PDFIUM_DIR:-$WORK_DIR/pdfium}"
PATCH_ROOT="${PATCH_ROOT:-$REPO_ROOT/patches}"
REPORT="${PATCH_REPORT:-$DIST_DIR/patch-report.txt}"
LOGS="$WORK_DIR/patch-logs"

[ -e "$PDFIUM_DIR/.git" ] || die 4 "no git checkout at $PDFIUM_DIR (run scripts/pdfium-checkout.sh first)"
[ ! -e "$PDFIUM_DIR/public/epdf_redact.h" ] || die 4 "the checkout already has the EmbedPDF files; apply the series to a fresh checkout"
if ! git -C "$PDFIUM_DIR" diff --quiet HEAD || ! git -C "$PDFIUM_DIR" diff --cached --quiet; then
  die 4 "the checkout has local changes; use a fresh checkout"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-patches-apply.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$LOGS"
mkdir -p "$LOGS" "$(dirname "$REPORT")"

# Patch list: pdfium-binaries first, then embedpdf, each in C-locale file-name order.
: >"$TMP/patches.txt"
for dir in pdfium-binaries embedpdf; do
  if [ -d "$PATCH_ROOT/$dir" ]; then
    find "$PATCH_ROOT/$dir" -maxdepth 1 -name '*.patch' -type f | LC_ALL=C sort >>"$TMP/patches.txt"
  fi
done
total="$(grep -c . "$TMP/patches.txt" || true)"
[ "$total" -gt 0 ] || die 4 "no patch files found under $PATCH_ROOT/pdfium-binaries or $PATCH_ROOT/embedpdf"

# --- helpers -------------------------------------------------------------------------------------------------
dir_key() { echo "$1" | sed 's#[^A-Za-z0-9]#_#g'; }

# remember <apply dir>: record the start commit and the untracked files of that checkout, once
remember() {
  local key target
  key="$(dir_key "$1")"
  [ ! -f "$TMP/start.$key" ] || return 0
  target="$PDFIUM_DIR/$1"
  git -C "$target" rev-parse HEAD >"$TMP/start.$key"
  git -C "$target" ls-files --others --exclude-standard | LC_ALL=C sort >"$TMP/untracked.$key"
  echo "$1" >>"$TMP/dirs.txt"
}

# restore <apply dir> <commit>: hard reset and remove untracked files that were not there at the start
restore() {
  local key target f
  key="$(dir_key "$1")"
  target="$PDFIUM_DIR/$1"
  git -C "$target" reset -q --hard "$2"
  git -C "$target" ls-files --others --exclude-standard | LC_ALL=C sort >"$TMP/untracked-now.$key"
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f -- "$target/$f"
  done < <(LC_ALL=C comm -13 "$TMP/untracked.$key" "$TMP/untracked-now.$key")
}

# head_of <apply dir>: the checkout's current commit, which is the last successfully applied patch
head_of() { git -C "$PDFIUM_DIR/$1" rev-parse HEAD; }

# If anything fails unexpectedly while patches are being applied, put every checkout back before exiting.
ARMED=0
cleanup() {
  local rc=$? d
  if [ "$ARMED" -eq 1 ] && [ -f "$TMP/dirs.txt" ]; then
    while IFS= read -r d; do
      restore "$d" "$(cat "$TMP/start.$(dir_key "$d")")" || true
    done <"$TMP/dirs.txt"
    echo "$SCRIPT_NAME: unexpected failure; the checkout was restored" >&2
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

: >"$TMP/dirs.txt"
: >"$TMP/results.txt"
applied=0
conflicted=0
hunks=0
files_total=0
re_dir='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'

# Check every Apply-Dir before anything is touched, so a bad header can never leave half a series behind.
while IFS= read -r patch; do
  d="$(sed -n 's/^# Apply-Dir: //p' "$patch" | head -1)"
  if [ -n "$d" ] && [ "$d" != "." ]; then
    if ! [[ "$d" =~ $re_dir ]] || [[ "$d" == *..* ]]; then
      die 2 "$(basename "$patch"): unsafe Apply-Dir '$d'"
    fi
  fi
done <"$TMP/patches.txt"

ARMED=1
while IFS= read -r patch; do
  name="$(basename "$patch")"
  apply_dir="$(sed -n 's/^# Apply-Dir: //p' "$patch" | head -1)"
  [ -n "$apply_dir" ] || apply_dir="."
  nfiles="$(grep -c '^diff --git a/' "$patch" || true)"

  if [ "$apply_dir" != "." ]; then
    if [ ! -e "$PDFIUM_DIR/$apply_dir/.git" ]; then
      conflicted=$((conflicted + 1))
      {
        echo "CONFLICT $name (apply dir $apply_dir)"
        echo "  apply dir is not a git checkout in this PDFium tree"
      } >>"$TMP/results.txt"
      continue
    fi
  fi

  remember "$apply_dir"
  target="$PDFIUM_DIR/$apply_dir"
  logfile="$LOGS/$name.log"
  patch_abs="$(cd "$(dirname "$patch")" && pwd)/$name"
  set +e
  git -C "$target" apply --reject --whitespace=nowarn "$patch_abs" >"$logfile" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    paths="$(grep '^diff --git a/' "$patch" | sed 's#^diff --git a/##; s# b/.*$##')"
    # -f: a path the patch names is staged even when this PDFium's .gitignore happens to match it.
    (cd "$target" && echo "$paths" | while IFS= read -r p; do git add -A -f -- "$p"; done)
    git -C "$target" -c user.name=pdf-engine-builds -c user.email=ci@invalid -c commit.gpgsign=false commit -q -m "apply $name"
    applied=$((applied + 1))
    files_total=$((files_total + nfiles))
    echo "APPLIED  $name ($nfiles files, apply dir $apply_dir)" >>"$TMP/results.txt"
  else
    conflicted=$((conflicted + 1))
    restore "$apply_dir" "$(head_of "$apply_dir")"
    {
      echo "CONFLICT $name (apply dir $apply_dir, $nfiles files in the patch)"
      sed -nE 's/^Applying patch (.*) with ([0-9]+) rejects?\.\.\.$/  rejected hunks: \1 (\2)/p' "$logfile"
      sed -nE 's/^error: (.*): No such file or directory$/  file does not exist in this PDFium: \1/p' "$logfile"
      sed -nE 's/^error: (.*): already exists in working directory$/  file already exists in this PDFium: \1/p' "$logfile"
      sed -nE 's/^error: (corrupt patch.*)$/  patch problem: \1/p' "$logfile"
    } >>"$TMP/results.txt"
    n="$(sed -nE 's/^Applying patch (.*) with ([0-9]+) rejects?\.\.\.$/\2/p' "$logfile" | awk '{s += $1} END {print s + 0}')"
    hunks=$((hunks + n))
  fi
done <"$TMP/patches.txt"

# --- report --------------------------------------------------------------------------------------------------
result=PASS
[ "$conflicted" -eq 0 ] || result=FAIL
pdfium_head="unknown"
[ ! -f "$WORK_DIR/pdfium-head.txt" ] || pdfium_head="$(cat "$WORK_DIR/pdfium-head.txt")"
{
  echo "patch-report v1"
  echo "result: $result"
  echo "pdfium_branch: ${PDFIUM_BRANCH:-unknown}"
  echo "pdfium_head: $pdfium_head"
  echo "embedpdf_commit: ${EMBEDPDF_COMMIT:-unknown}"
  echo "embedpdf_upstream_base: ${EMBEDPDF_UPSTREAM_BASE:-unknown}"
  echo "patches: $total"
  echo "applied: $applied"
  echo "conflicted: $conflicted"
  echo "hunks_rejected: $hunks"
  if [ "$result" = PASS ]; then
    echo "files_changed: $files_total"
  else
    echo "files_changed: 0 (the series was rolled back)"
  fi
  echo "--"
  cat "$TMP/results.txt"
} >"$REPORT"

if [ "$conflicted" -gt 0 ]; then
  while IFS= read -r d; do
    restore "$d" "$(cat "$TMP/start.$(dir_key "$d")")"
  done <"$TMP/dirs.txt"
  ARMED=0
  cat "$REPORT"
  die 1 "$conflicted of $total patch(es) conflicted; the checkout was restored and nothing is applied"
fi
ARMED=0
cat "$REPORT"
log "applied $applied patch(es), $files_total files changed"
