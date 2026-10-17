#!/usr/bin/env bash
# Usage: scripts/pdfium-patches-export.sh [--check]
# Derives the EmbedPDF patch series from the fork: the difference between EMBEDPDF_UPSTREAM_BASE (the PDFium
# commit the fork last merged) and EMBEDPDF_COMMIT, both pinned in versions.env, split by area into
# patches/embedpdf/000N-<area>.patch. The fork's CI files, its own build patches, its scripts, its NOTICE and
# .gitignore are left out (listed in EXCLUDED.txt); everything else it changed is in the series, so the result
# builds the same extension API the fork ships. The fork's Skia patch is copied as the last patch.
#   no flag:  writes patches/embedpdf/ (all or nothing: a failed run leaves the old series untouched)
#   --check:  writes nothing; exits 1 when the committed series differs from what the pins would produce
# Environment (optional): WORK_DIR, PATCH_OUT_DIR (default patches/embedpdf), GIT_BIN, GH_BIN.
# Exit codes: 0 ok, 1 --check found a difference, 2 bad pins or missing tool, 3 the pinned commits are not a valid
# fork/upstream pair, 4 git or network failure, 5 the patches do not cover exactly the files that changed.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

# Patch files carry binary and non-UTF-8 bytes: BSD sed and grep abort on them in a UTF-8 locale.
export LC_ALL=C

CHECK=0
case "${1:-}" in
  '') ;;
  --check) CHECK=1 ;;
  *) die 2 "usage: $SCRIPT_NAME [--check]" ;;
esac
[ "$#" -le 1 ] || die 2 "usage: $SCRIPT_NAME [--check]"

GIT="${GIT_BIN:-git}"
GH="${GH_BIN:-gh}"
PATCH_OUT_DIR="${PATCH_OUT_DIR:-$REPO_ROOT/patches/embedpdf}"
RT="$WORK_DIR/embedpdf-runtime"

require_env EMBEDPDF_REPO EMBEDPDF_COMMIT EMBEDPDF_UPSTREAM_BASE
is_hex40 "$EMBEDPDF_COMMIT" || die 2 "EMBEDPDF_COMMIT must be a full 40-character SHA"
is_hex40 "$EMBEDPDF_UPSTREAM_BASE" || die 2 "EMBEDPDF_UPSTREAM_BASE must be a full 40-character SHA"
[ "$EMBEDPDF_COMMIT" != "$EMBEDPDF_UPSTREAM_BASE" ] || die 2 "EMBEDPDF_COMMIT and EMBEDPDF_UPSTREAM_BASE must differ"
require_cmd "$GIT" shasum
BASE="$EMBEDPDF_UPSTREAM_BASE"
HEAD_SHA="$EMBEDPDF_COMMIT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-patches-export.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# 1. Fetch exactly the two commits (history-free, without file contents until a diff needs them).
mkdir -p "$WORK_DIR"
if [ ! -d "$RT/.git" ]; then
  log "cloning $EMBEDPDF_REPO (no checkout, no history, no file contents)"
  "$GIT" clone --quiet --no-checkout --no-tags --depth=1 --filter=blob:none "$EMBEDPDF_REPO" "$RT" || die 4 "could not clone $EMBEDPDF_REPO"
fi
"$GIT" -C "$RT" fetch --quiet --no-tags --depth=1 origin "$HEAD_SHA" "$BASE" || die 4 "could not fetch the pinned commits from $EMBEDPDF_REPO (does $BASE or $HEAD_SHA exist?)"
for sha in "$HEAD_SHA" "$BASE"; do
  "$GIT" -C "$RT" cat-file -e "$sha^{commit}" 2>/dev/null || die 3 "commit $sha is not in the fetched repository"
done
"$GIT" -C "$RT" cat-file -e "$HEAD_SHA:public/epdf_redact.h" 2>/dev/null || die 3 "EMBEDPDF_COMMIT has no public/epdf_redact.h; it is not an EmbedPDF runtime commit"
if "$GIT" -C "$RT" cat-file -e "$BASE:public/epdf_redact.h" 2>/dev/null; then
  die 3 "EMBEDPDF_UPSTREAM_BASE already has public/epdf_redact.h; it must be a plain upstream PDFium commit"
fi

# 2. The base must be an ancestor of the fork commit (checked on GitHub, where the full history is).
slug_re='^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$'
if [[ "$EMBEDPDF_REPO" =~ $slug_re ]]; then
  require_cmd "$GH"
  status="$("$GH" api "repos/${BASH_REMATCH[1]}/compare/${BASE}...${HEAD_SHA}" --jq .status 2>/dev/null)" || die 4 "GitHub compare failed for the two pins"
  case "$status" in
    ahead | identical) ;;
    *) die 3 "EMBEDPDF_UPSTREAM_BASE is not an ancestor of EMBEDPDF_COMMIT (GitHub says '$status')" ;;
  esac
else
  warn "ancestry check skipped: $EMBEDPDF_REPO is not a github.com URL"
fi

# 3. Classify every changed path.
classify() { # <path> -> group name or "excluded"
  case "$1" in
    .github/* | patches/* | scripts/* | docs/* | .gitignore | .gitattributes | NOTICE | README.md | LICENSE | AUTHORS | OWNERS | DEPS)
      echo excluded
      ;;
    testing/* | *_unittest.cpp | *_embeddertest.cpp | *_test.c) echo 0006-tests ;;
    public/*) echo 0001-public-headers ;;
    core/fpdfapi/*) echo 0003-fpdfapi ;;
    core/fpdfdoc/*) echo 0004-fpdfdoc ;;
    fpdfsdk/*) echo 0005-fpdfsdk ;;
    *) echo 0002-foundation ;;
  esac
}
GROUPS_IN_ORDER="0001-public-headers 0002-foundation 0003-fpdfapi 0004-fpdfdoc 0005-fpdfsdk 0006-tests"
: >"$TMP/all-included.txt"
for g in $GROUPS_IN_ORDER; do : >"$TMP/paths.$g"; done
while IFS= read -r -d '' path; do
  group="$(classify "$path")"
  if [ "$group" = excluded ]; then
    printf '%s\n' "$path" >>"$TMP/excluded.txt"
  else
    printf '%s\0' "$path" >>"$TMP/paths.$group"
    printf '%s\n' "$path" >>"$TMP/all-included.txt"
  fi
done < <("$GIT" -C "$RT" -c core.quotepath=off diff --name-only -z --no-renames "$BASE" "$HEAD_SHA")
[ -s "$TMP/all-included.txt" ] || die 3 "no changed files between the two pins"
touch "$TMP/excluded.txt"
if grep -qx 'DEPS' "$TMP/excluded.txt"; then
  warn "the fork changed DEPS; the series does not carry it, so review that change by hand (dependency pins differ from upstream)"
fi

# 4. One patch per group, each with a provenance header.
mkdir -p "$TMP/out"
header() { # <group> <file count> <apply dir> <license text> [extra header lines...]
  local group="$1" count="$2" dir="$3" license="$4"
  shift 4
  echo "# EmbedPDF extension patch series for PDFium. Generated by scripts/pdfium-patches-export.sh; do not edit by hand."
  echo "# Source: $EMBEDPDF_REPO"
  echo "# Source-Commit: $HEAD_SHA"
  echo "# Upstream-Base: $BASE (the PDFium commit the fork last merged; this patch is the fork's change on top of it)"
  echo "# Group: $group"
  echo "# Files: $count"
  echo "# License: $license"
  while [ "$#" -gt 0 ]; do
    echo "# $1"
    shift
  done
  echo "# Apply-Dir: $dir"
  echo "#"
}
LICENSE_MAIN="files marked SPDX-License-Identifier: Apache-2.0 are Apache-2.0 (CloudPDF LTD); PDFium-derived files stay BSD-3-Clause (The PDFium Authors)"
for g in $GROUPS_IN_ORDER; do
  count="$(tr -cd '\0' <"$TMP/paths.$g" | wc -c | tr -d ' ')"
  [ "$count" -gt 0 ] || continue
  # git diff has no --pathspec-from-file, so the paths go on the command line (a few hundred at most).
  # --literal-pathspecs: a file name is never read as a glob.
  specs=()
  while IFS= read -r -d '' p; do
    specs+=("$p")
  done <"$TMP/paths.$g"
  {
    header "$g" "$count" "." "$LICENSE_MAIN"
    "$GIT" --literal-pathspecs -C "$RT" -c core.quotepath=off -c core.autocrlf=false diff --binary --full-index --no-renames \
      --no-ext-diff --no-color --diff-algorithm=myers -U3 --src-prefix=a/ --dst-prefix=b/ "$BASE" "$HEAD_SHA" -- "${specs[@]}"
  } >"$TMP/out/$g.patch" || die 4 "git diff failed for group $g"
  log "$g: $count file(s)"
done

# 5. The fork's own Skia patch (it lives in the fork repo as a patch file; Skia is a separate git checkout).
SKIA_SRC="patches/embedpdf-runtime/skia/geometry-only-stroke.patch"
"$GIT" -C "$RT" cat-file -e "$HEAD_SHA:$SKIA_SRC" 2>/dev/null || die 3 "the fork has no $SKIA_SRC at EMBEDPDF_COMMIT"
{
  header 0007-skia-geometry-only-stroke 1 "third_party/skia" "BSD-3-Clause (Skia; see the file headers inside the patch)" \
    "Source-Path: $SKIA_SRC" "Purpose: lets the redaction code use Skia path stroking without linking Skia's paint, shader and font graph"
  "$GIT" -C "$RT" cat-file blob "$HEAD_SHA:$SKIA_SRC"
} >"$TMP/out/0007-skia-geometry-only-stroke.patch" || die 4 "could not read the Skia patch"

# 6. Coverage: the patches must touch exactly the changed files that are not excluded.
for p in "$TMP"/out/000[1-6]-*.patch; do
  grep -h '^diff --git a/' "$p" | sed 's#^diff --git a/##; s# b/.*$##'
done | LC_ALL=C sort >"$TMP/in-patches.txt"
LC_ALL=C sort "$TMP/all-included.txt" >"$TMP/expected.txt"
if ! cmp -s "$TMP/in-patches.txt" "$TMP/expected.txt"; then
  diff "$TMP/expected.txt" "$TMP/in-patches.txt" | head -20 >&2 || true
  die 5 "the patches do not cover exactly the changed files (first differences above)"
fi
LC_ALL=C sort "$TMP/excluded.txt" >"$TMP/out/EXCLUDED.txt"

# 7. SOURCE.txt records what was exported (the checksums make drift visible in review).
{
  echo "source_repo=$EMBEDPDF_REPO"
  echo "source_commit=$HEAD_SHA"
  echo "upstream_base=$BASE"
  for p in "$TMP"/out/*.patch; do
    echo "patch=$(basename "$p") sha256=$(shasum -a 256 "$p" | awk '{print $1}') files=$(grep -c '^diff --git a/' "$p")"
  done
  echo "excluded_files=$(grep -c . "$TMP/out/EXCLUDED.txt")"
} >"$TMP/out/SOURCE.txt"

# 8. Publish all at once, or compare.
if [ "$CHECK" -eq 1 ]; then
  drift=0
  for f in "$TMP"/out/*; do
    cmp -s "$f" "$PATCH_OUT_DIR/$(basename "$f")" || {
      echo "DIFFERS: $(basename "$f")"
      drift=1
    }
  done
  for f in "$PATCH_OUT_DIR"/[0-9][0-9][0-9][0-9]-*.patch; do
    [ -e "$f" ] || continue
    [ -f "$TMP/out/$(basename "$f")" ] || {
      echo "STALE (not produced by the pins): $(basename "$f")"
      drift=1
    }
  done
  [ "$drift" -eq 0 ] || {
    echo "pdfium-patches-export: the committed series does not match the pins; run scripts/pdfium-patches-export.sh and review the diff"
    exit 1
  }
  log "committed series matches the pins"
  exit 0
fi
mkdir -p "$PATCH_OUT_DIR"
rm -f "$PATCH_OUT_DIR"/[0-9][0-9][0-9][0-9]-*.patch "$PATCH_OUT_DIR/SOURCE.txt" "$PATCH_OUT_DIR/EXCLUDED.txt"
cp "$TMP"/out/* "$PATCH_OUT_DIR/"
log "wrote $(ls "$PATCH_OUT_DIR"/*.patch | wc -l | tr -d ' ') patch(es) to $PATCH_OUT_DIR"
