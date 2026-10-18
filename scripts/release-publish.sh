#!/usr/bin/env bash
# Usage: scripts/release-publish.sh <tag> [--dry-run]
#
# The all-or-nothing gate in front of `gh release create`. It checks everything that goes into
# dist/ first and publishes only when every check passes:
#   1. the tag is valid for scripts/release-tag.sh: v<major>.<minor>.<patch>-pdfium<NNNN>[-stock][-macos-only]
#      with NNNN equal to the PDFium branch number pinned in versions.env
#   2. dist/ holds exactly the release assets (full release: PDFium.xcframework.zip,
#      QPDF.xcframework.zip, LICENSES.zip, checksums.txt; "-macos-only": PDFium.xcframework.zip and
#      checksums.txt) and every SHA-256 in checksums.txt matches (scripts/checksums.sh verify)
#   3. each XCFramework zip unpacks to a framework with exactly the expected slices (full release:
#      macos-arm64, ios-arm64, ios-arm64-simulator; "-macos-only": macos-arm64), built for the right
#      platform, with headers; PDFium's headers in the layout the contract fixes in every slice
#      (Headers/module.modulemap at the root naming `umbrella header "PDFium/PDFium.h"`, the
#      umbrella header in Headers/PDFium/, no PDFium.h at the Headers root)
#   4. in every slice, libpdfium.a and libqpdf.a define no symbol in common: both carry a libjpeg, and in a
#      static link the first archive that defines a name wins, so a shared name could silently bind qpdf to
#      PDFium's copy (or the other way round) with no link error. nm failing, listing no definitions, or not
#      listing the engine's anchor symbol (_FPDF_InitLibrary in PDFium, _qpdf_init from qpdf's C API) refuses.
#   5. LICENSES.zip holds a README.txt, the PDFium notices, the pdfium-binaries MIT text and the qpdf notices
# With --dry-run it stops there. Otherwise it creates a DRAFT release with the assets, compares the
# SHA-256 GitHub computed for each uploaded asset with the local one, and only then publishes the
# draft. If anything fails after the draft exists, the draft is deleted. The tag must already exist
# on GitHub (--verify-tag), so this script can never create a tag.
#
# Environment (optional): RELEASE_REPO (default WhiteLotusLA/pdf-engine-builds), GH_BIN (default gh),
# DIST_DIR (default <repo>/dist).
# Exit codes: 0 ok, 1 a check failed (nothing was published), 2 usage, tool missing or malformed tag,
#             3 the tag does not match the PDFium pin in versions.env,
#             6 GitHub's checksums disagreed with the local files (draft deleted),
#             7 the draft could not be created (then deleted) or could not be published (left in place for inspection).
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

GH="${GH_BIN:-gh}"
RELEASE_REPO="${RELEASE_REPO:-WhiteLotusLA/pdf-engine-builds}"

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die 2 "usage: release-publish.sh <tag> [--dry-run]"
TAG="$1"
DRY=0
if [ "${2:-}" = "--dry-run" ]; then
  DRY=1
elif [ -n "${2:-}" ]; then
  die 2 "unknown option: $2"
fi
require_cmd "$GH" jq shasum ditto nm comm

# --- 1. the tag ---
# release-tag.sh checks the grammar and that the PDFium number matches PDFIUM_BRANCH in versions.env
# (exit 2 malformed, 3 mismatch) and prints key=value lines.
tag_info="$("$COMMON_SH_DIR/release-tag.sh" "$TAG")" || exit $?
MACOS_ONLY=0
PRERELEASE=0
grep -qx 'macos_only=true' <<<"$tag_info" && MACOS_ONLY=1
grep -qx 'prerelease=true' <<<"$tag_info" && PRERELEASE=1
require_env PDFIUM_BRANCH

if [ "$MACOS_ONLY" -eq 1 ]; then
  ASSETS="PDFium.xcframework.zip"
  PDFIUM_SLICES="macos-arm64"
  QPDF_SLICES=""
else
  ASSETS="PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip"
  PDFIUM_SLICES="macos-arm64 ios-arm64 ios-arm64-simulator"
  QPDF_SLICES="macos-arm64 ios-arm64 ios-arm64-simulator"
fi

# --- 2. assets and checksums ---
"$COMMON_SH_DIR/checksums.sh" verify "$DIST_DIR" || die 1 "checksums.txt does not match the files in $DIST_DIR"
expected="$(printf '%s\n' $ASSETS | LC_ALL=C sort | tr '\n' ' ')"
listed="$(awk '{ sub(/^\*/, "", $2); print $2 }' "$DIST_DIR/checksums.txt" | LC_ALL=C sort | tr '\n' ' ')"
present="$(cd "$DIST_DIR" && ls -1 ./*.zip 2>/dev/null | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ' || true)"
[ "$listed" = "$expected" ] || die 1 "checksums.txt lists '${listed% }' but this release must contain exactly '${expected% }'"
[ "$present" = "$expected" ] || die 1 "zip files in $DIST_DIR are '${present% }' but this release must contain exactly '${expected% }'"

# --- 3. the frameworks ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-publish.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

check_framework() { # <Name> <slices...>
  local name="$1" id headers
  shift
  mkdir -p "$TMP/$name"
  ditto -x -k "$DIST_DIR/$name.xcframework.zip" "$TMP/$name"
  [ -d "$TMP/$name/$name.xcframework" ] || die 1 "$name.xcframework.zip does not contain $name.xcframework at its top level"
  "$COMMON_SH_DIR/verify-xcframework.sh" "$TMP/$name/$name.xcframework" "$@" || die 1 "$name.xcframework failed verification"
  if [ "$name" = "PDFium" ]; then
    for id in "$@"; do
      headers="$TMP/$name/$name.xcframework/$id/Headers"
      [ -f "$headers/module.modulemap" ] || die 1 "PDFium slice $id has no Headers/module.modulemap"
      [ -f "$headers/PDFium/PDFium.h" ] || die 1 "PDFium slice $id has no Headers/PDFium/PDFium.h"
      grep -Eq '^[[:space:]]*umbrella header "PDFium/PDFium\.h"[[:space:]]*$' "$headers/module.modulemap" \
        || die 1 "PDFium slice $id: Headers/module.modulemap must name umbrella header \"PDFium/PDFium.h\" (this is the old header layout)"
      [ ! -e "$headers/PDFium.h" ] || die 1 "PDFium slice $id has a PDFium.h at the Headers root; the umbrella header belongs in Headers/PDFium/ only"
    done
  fi
}
# shellcheck disable=SC2086
check_framework PDFium $PDFIUM_SLICES
if [ -n "$QPDF_SLICES" ]; then
  # shellcheck disable=SC2086
  check_framework QPDF $QPDF_SLICES
fi

# --- 4. no symbol defined by both engines ---
defs() { # <archive> <anchor symbol> <out file>: writes every non-weak external or private external definition,
  # one name per line, sorted under LC_ALL=C. nm runs on its own, never in a pipe or a process substitution, so
  # its failure refuses the release; an empty list or a missing anchor symbol (one the engine's public API always
  # defines) refuses too, because "no symbol in common" means nothing unless both lists are real.
  local lib="$1" anchor="$2" out="$3"
  nm -m "$lib" >"$out.nm" 2>"$out.err" || die 1 "nm failed on $lib: $(head -1 "$out.err")"
  { grep -E ' (private )?external ' "$out.nm" || true; } | { grep -v -e ' weak ' -e '(undefined)' || true; } \
    | awk '{print $NF}' | LC_ALL=C sort -u >"$out"
  [ -s "$out" ] || die 1 "nm lists no defined symbol in $lib; refusing to call the symbol check passed"
  grep -qx -- "$anchor" "$out" || die 1 "$lib does not define $anchor, so it is not the archive this release must ship"
}
slice_lib() { # <slice dir>: prints the static library inside it
  local f
  for f in "$1"/*.a; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done
  return 1
}
# shellcheck disable=SC2086
for id in $QPDF_SLICES; do
  plib="$(slice_lib "$TMP/PDFium/PDFium.xcframework/$id")" && qlib="$(slice_lib "$TMP/QPDF/QPDF.xcframework/$id")" \
    || die 1 "slice $id: no static library in PDFium.xcframework or QPDF.xcframework"
  defs "$plib" _FPDF_InitLibrary "$TMP/pdfium-$id.defs"
  defs "$qlib" _qpdf_init "$TMP/qpdf-$id.defs"
  both="$(LC_ALL=C comm -12 "$TMP/pdfium-$id.defs" "$TMP/qpdf-$id.defs")"
  [ -z "$both" ] || die 1 "PDFium and QPDF both define $(printf '%s\n' "$both" | wc -l | tr -d ' ') symbol(s) in slice $id (first: $(printf '%s\n' "$both" | head -1)); rename or drop one copy in scripts/qpdf-build.sh"
done

# --- 5. the notices ---
if [ "$MACOS_ONLY" -eq 0 ]; then
  mkdir -p "$TMP/LICENSES"
  ditto -x -k "$DIST_DIR/LICENSES.zip" "$TMP/LICENSES"
  for f in README.txt pdfium/pdfium.txt pdfium-binaries/LICENSE qpdf/LICENSE.txt; do
    [ -s "$TMP/LICENSES/LICENSES/$f" ] || die 1 "LICENSES.zip is missing LICENSES/$f"
  done
fi

FILES=""
for a in $ASSETS checksums.txt; do FILES="$FILES $DIST_DIR/$a"; done
if [ "$DRY" -eq 1 ]; then
  log "dry run: all checks passed; would publish $TAG to $RELEASE_REPO with:$FILES"
  exit 0
fi

# --- publish: draft, compare GitHub's checksums, then publish ---
NOTES="$TMP/notes.md"
{
  echo "PDFium branch $PDFIUM_BRANCH; qpdf $QPDF_VERSION; libjpeg-turbo $LIBJPEG_TURBO_VERSION."
  echo "Slices: $PDFIUM_SLICES. Verify the downloads against checksums.txt (SHA-256)."
  echo "Third-party notices are in LICENSES.zip."
} >"$NOTES"

delete_draft() {
  "$GH" release delete "$TAG" --repo "$RELEASE_REPO" --yes >/dev/null 2>&1 || warn "could not delete the draft release $TAG; delete it by hand"
}

flags=(--repo "$RELEASE_REPO" --draft --verify-tag --title "$TAG" --notes-file "$NOTES")
if [ "$PRERELEASE" -eq 1 ]; then flags+=(--prerelease); else flags+=(--latest); fi
# shellcheck disable=SC2086
"$GH" release create "$TAG" "${flags[@]}" $FILES || { delete_draft; die 7 "could not create the draft release $TAG; nothing is published"; }

listing="$("$GH" api "repos/$RELEASE_REPO/releases?per_page=100" | jq -r --arg t "$TAG" '[.[] | select(.tag_name == $t and .draft == true)][0] | .assets[]? | [.name, .digest] | @tsv')" \
  || { delete_draft; die 6 "could not read the draft release back from GitHub"; }

for f in $FILES; do
  name="$(basename "$f")"
  want="sha256:$(shasum -a 256 "$f" | awk '{print $1}')"
  got="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' <<<"$listing")"
  if [ "$got" != "$want" ]; then
    delete_draft
    die 6 "GitHub reports '${got:0:19}...' for $name but the local file is '${want:0:19}...'; the draft release was deleted"
  fi
done
count="$(grep -c . <<<"$listing" || true)"
if [ "$count" -ne "$(printf '%s\n' $FILES | wc -l | tr -d ' ')" ]; then
  delete_draft
  die 6 "the draft release holds $count assets but $(printf '%s\n' $FILES | wc -l | tr -d ' ') were uploaded; the draft release was deleted"
fi

"$GH" release edit "$TAG" --repo "$RELEASE_REPO" --draft=false \
  || die 7 "could not publish the draft release $TAG; it is still a draft on GitHub"
log "published $TAG to $RELEASE_REPO"
