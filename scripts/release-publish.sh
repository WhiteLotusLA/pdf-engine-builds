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
#   5. LICENSES.zip holds, each non-empty, a README.txt and every notice licenses.sh adds for a full release:
#      PDFium and the libraries linked into it (skia, libyuv, zlib, freetype), the pdfium-binaries MIT text,
#      EmbedPDF's LICENSE and NOTICE, qpdf's LICENSE and NOTICE, libjpeg-turbo's two texts, and this repo's own
# With --dry-run it stops there and never calls gh. Otherwise:
#   6. it refuses, with nothing touched, when any release or draft already exists for the tag: the releases
#      listing (which shows drafts to a writer) must not name the tag, and repos/<repo>/releases/tags/<tag>
#      must answer 404 (any other answer or error refuses)
#   7. it creates a DRAFT release with the assets, then requires exactly one release for the tag, a draft, and
#      works only by that draft's numeric id from then on (gh release edit|delete <tag> would pick a
#      published release before a draft): it reads the draft back by id, compares the SHA-256 GitHub computed
#      for each asset with the local file and the asset count, and only then publishes it with
#      PATCH releases/<id> draft=false (make_latest=true for a full release, prerelease=true for
#      "-stock-macos-only"). A release is deleted only by id and only while GitHub still reports it as a draft.
# The tag must already exist on GitHub (--verify-tag), so this script can never create a tag.
#
# Environment (optional): RELEASE_REPO (default WhiteLotusLA/pdf-engine-builds), GH_BIN (default gh),
# DIST_DIR (default <repo>/dist).
# Exit codes: 0 ok, 1 a check failed, or a release or draft already exists for the tag, or GitHub could not
#               confirm that none does (nothing was created or published),
#             2 usage, tool missing or malformed tag,
#             3 the tag does not match the PDFium pin in versions.env,
#             6 GitHub's checksums or asset list disagreed with the local files, or the draft could not be read
#               back (the draft was deleted by its id; nothing was published),
#             7 the draft could not be created (a partial draft is deleted by its id), the releases for the tag
#               after create were not exactly one draft (nothing deleted), or the draft could not be published
#               (left in place for inspection).
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
# Every notice scripts/licenses.sh assemble adds for a full release, each non-empty. A full release always carries
# the EmbedPDF patches (release.yml builds the patched variant for every tag that is not -stock-macos-only), so
# embedpdf/ is required whatever the checkout's patches/ folder holds. Skia (patch 0002's path code) and libyuv
# are linked into libpdfium.a; zlib and freetype are linked into every PDFium build.
REQUIRED_NOTICES="README.txt pdfium/pdfium.txt pdfium/skia.txt pdfium/libyuv.txt pdfium/zlib.txt pdfium/freetype.txt
  pdfium-binaries/LICENSE embedpdf/LICENSE embedpdf/NOTICE qpdf/LICENSE.txt qpdf/NOTICE.md
  libjpeg-turbo/LICENSE.md libjpeg-turbo/README.ijg pdf-engine-builds/LICENSE pdf-engine-builds/NOTICE"
if [ "$MACOS_ONLY" -eq 0 ]; then
  mkdir -p "$TMP/LICENSES"
  ditto -x -k "$DIST_DIR/LICENSES.zip" "$TMP/LICENSES"
  for f in $REQUIRED_NOTICES; do
    [ -s "$TMP/LICENSES/LICENSES/$f" ] || die 1 "LICENSES.zip is missing LICENSES/$f (or it is empty)"
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

# Every release is addressed by its numeric id, never by its tag: `gh release edit|delete <tag>` resolve a tag to
# a published release before a draft, so a rerun after publishing could delete the release Engines.lock pins.
releases_for_tag() { # prints "<id><TAB><draft>" for every release or draft whose tag is $TAG
  # The REST listing shows drafts to a writer; --paginate reads every page (gh prints one array per page, or one
  # merged array; jq -s takes either).
  "$GH" api --paginate "repos/$RELEASE_REPO/releases?per_page=100" >"$TMP/releases.json" || return 1
  jq -r -s --arg t "$TAG" '[.[][] | select(.tag_name == $t)] | .[] | [(.id | tostring), (.draft | tostring)] | @tsv' "$TMP/releases.json"
}
delete_draft() { # <id>: deletes that release only while GitHub still reports it as a draft for $TAG
  local id="$1"
  if ! "$GH" api "repos/$RELEASE_REPO/releases/$id" >"$TMP/delete-check.json" 2>/dev/null \
    || ! jq -e --arg t "$TAG" '.draft == true and .tag_name == $t' "$TMP/delete-check.json" >/dev/null 2>&1; then
    warn "release $id was not deleted: GitHub does not report it as a draft for $TAG; check it by hand"
    return 0
  fi
  if "$GH" api -X DELETE "repos/$RELEASE_REPO/releases/$id" >/dev/null 2>&1; then
    log "deleted the draft release $id ($TAG)"
  else
    warn "could not delete the draft release $id ($TAG); delete it by hand"
  fi
}

# Nothing may exist for the tag yet, neither a published release (a rerun after publishing) nor a draft (left by
# an earlier run): the listing must not name the tag, and the tag lookup, which finds published releases only,
# must answer 404. Anything else, including any other error, refuses with nothing touched.
rows="$(releases_for_tag)" || die 1 "could not list the releases of $RELEASE_REPO; nothing was created"
[ -z "$rows" ] || die 1 "$RELEASE_REPO already has a release or draft for $TAG (id and draft: $(tr '\t\n' '= ' <<<"$rows")); nothing was created. A published release is never replaced; check a leftover draft and delete it by hand"
tag_code=0
"$GH" api -i "repos/$RELEASE_REPO/releases/tags/$TAG" >"$TMP/tag-lookup.txt" 2>"$TMP/tag-lookup.err" || tag_code=$?
tag_status="$(head -1 "$TMP/tag-lookup.txt" | tr -d '\r' | awk '{print $2}')"
[ "$tag_code" -ne 0 ] || die 1 "$RELEASE_REPO already has a published release for $TAG; nothing was created"
[ "$tag_status" = 404 ] || die 1 "could not confirm that $TAG has no published release (gh api exit $tag_code, HTTP status '${tag_status:-none}'); nothing was created"

flags=(--repo "$RELEASE_REPO" --draft --verify-tag --title "$TAG" --notes-file "$NOTES")
if [ "$PRERELEASE" -eq 1 ]; then flags+=(--prerelease); else flags+=(--latest); fi
created=1
# shellcheck disable=SC2086
"$GH" release create "$TAG" "${flags[@]}" $FILES || created=0

# After create, exactly one release may carry the tag, and it must be a draft: this run's.
rows="$(releases_for_tag)" || die 7 "could not list the releases of $RELEASE_REPO after creating the draft for $TAG; nothing was published; delete any draft for $TAG by hand"
n="$(grep -c . <<<"$rows" || true)"
if [ "$created" -eq 0 ]; then
  # None existed before create, so a single draft for the tag now is this run's partial draft.
  if [ "$n" -eq 1 ] && [ "$(cut -f2 <<<"$rows")" = true ]; then
    delete_draft "$(cut -f1 <<<"$rows")"
  elif [ "$n" -gt 0 ]; then
    warn "$n release(s) for $TAG after the failed create; none was deleted; check them by hand"
  fi
  die 7 "could not create the draft release $TAG; nothing is published"
fi
if [ "$n" -ne 1 ] || [ "$(cut -f2 <<<"$rows")" != true ]; then
  die 7 "after create, $RELEASE_REPO has $n release(s) for $TAG instead of exactly one draft (id and draft: $(tr '\t\n' '= ' <<<"$rows")); nothing was published or deleted; check them by hand"
fi
ID="$(cut -f1 <<<"$rows")"
[[ "$ID" =~ ^[0-9]+$ ]] || die 7 "GitHub gave the draft for $TAG an id that is not a number: '$ID'; nothing was published"

# Read the draft's assets by its id and compare the SHA-256 GitHub computed for each with the local file.
if ! "$GH" api "repos/$RELEASE_REPO/releases/$ID" >"$TMP/draft.json" \
  || ! listing="$(jq -r --arg t "$TAG" 'if .tag_name == $t and .draft == true then (.assets[] | [.name, (.digest // "")] | @tsv) else error("not the draft for this tag") end' "$TMP/draft.json")"; then
  delete_draft "$ID"
  die 6 "could not read the draft release $ID back from GitHub; nothing was published"
fi
for f in $FILES; do
  name="$(basename "$f")"
  want="sha256:$(shasum -a 256 "$f" | awk '{print $1}')"
  got="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' <<<"$listing")"
  if [ "$got" != "$want" ]; then
    delete_draft "$ID"
    die 6 "GitHub reports '${got:0:19}...' for $name but the local file is '${want:0:19}...'; nothing was published"
  fi
done
count="$(grep -c . <<<"$listing" || true)"
if [ "$count" -ne "$(printf '%s\n' $FILES | wc -l | tr -d ' ')" ]; then
  delete_draft "$ID"
  die 6 "the draft release holds $count assets but $(printf '%s\n' $FILES | wc -l | tr -d ' ') were uploaded; nothing was published"
fi

# Publish by id. A full release is marked latest explicitly; a pre-release stays a pre-release and is never latest.
# (make_latest is a string in GitHub's API, hence -f; draft and prerelease are booleans, hence -F.)
publish_fields=(-F draft=false)
if [ "$PRERELEASE" -eq 1 ]; then publish_fields+=(-F prerelease=true); else publish_fields+=(-f make_latest=true); fi
"$GH" api -X PATCH "repos/$RELEASE_REPO/releases/$ID" "${publish_fields[@]}" >"$TMP/published.json" \
  || die 7 "could not publish the draft release $TAG (id $ID); it is still a draft on GitHub"
jq -e --arg t "$TAG" '.draft == false and .tag_name == $t' "$TMP/published.json" >/dev/null \
  || die 7 "GitHub did not confirm that release $ID ($TAG) is published; check it by hand"
log "published $TAG to $RELEASE_REPO (release id $ID)"
