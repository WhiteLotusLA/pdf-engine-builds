#!/usr/bin/env bash
# Self-test for scripts/release-publish.sh with a fake gh (no network); it uses scripts/checksums.sh from task A2.
# The release is all-or-nothing, so every case below that must NOT publish also asserts that the
# fake gh never saw `release create` (or, after a server-side mismatch, that the draft was deleted
# by its id and never published). The fake gh keeps a release table (a JSON array like GitHub's
# listing), so the cases can start with a published release or a leftover draft for the tag and
# check what the gate left behind.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "release-gate-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
# shellcheck source=../../versions.env
. "$REPO/versions.env"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=tiny-xcframework.sh
. "$REPO/scripts/tests/tiny-xcframework.sh"
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
out=""
code=0
LOG="$WORK/gh.log"
export FAKE_GH_LOG="$LOG"

# --- fake gh ---
# Logs every call to $FAKE_GH_LOG and keeps the releases in $FAKE_RELEASES (objects with id, tag_name,
# draft, prerelease and assets [{name, digest}]). It answers only the calls the gate may make:
#   release create <tag> ... <files>          adds a draft (ids count up from 1); --notes-file is copied to $FAKE_GH_NOTES
#   api --paginate repos/R/releases?per_page=100   the table (drafts included, as GitHub shows a writer)
#   api -i repos/R/releases/tags/<tag>        the published release for the tag, else HTTP 404 (drafts are never found by tag)
#   api repos/R/releases/<id>                 one release by id
#   api -X PATCH repos/R/releases/<id> -F draft=false [-F prerelease=true | -f make_latest=true]
#   api -X DELETE repos/R/releases/<id>
# Anything else (release edit, release delete by tag, ...) fails as an unexpected call.
# Knobs: FAKE_CREATE_FAIL=1 (create uploads only the first asset, then fails) or =nodraft (fails before
# any draft exists); FAKE_CREATE_PUBLISHED=1 (the new release is not a draft); FAKE_SECOND_DRAFT=1 (a
# second draft with the same tag appears); FAKE_WRONG_DIGEST=<asset> and FAKE_NULL_DIGEST=<asset>;
# FAKE_EXTRA_ASSET=1; FAKE_LISTING_HIDES=1 (the listing is empty); FAKE_API_FAIL=<glob over "METHOD path">
# (HTTP 500), with FAKE_API_FAIL_ONCE=1 only the first match fails; FAKE_FLIP_ON_GET=<n> (from the n-th
# read of a release by id on, that release is published, as if someone else published it).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$FAKE_GH_LOG"
T="$FAKE_RELEASES"
edit_table() { jq -c "$@" "$T" >"$T.new" && mv "$T.new" "$T"; }
bump() { # <counter name>: prints how many times it was bumped, this time included
  local f="$T.count-$1" n=0
  if [ -f "$f" ]; then n="$(cat "$f")"; fi
  n=$((n + 1))
  echo "$n" >"$f"
  echo "$n"
}
add_release() { # <tag> <draft> <prerelease> <assets JSON>
  edit_table --arg t "$1" --argjson d "$2" --argjson p "$3" --argjson a "$4" \
    '. + [{id: ((map(.id) | max // 0) + 1), tag_name: $t, draft: $d, prerelease: $p, assets: $a}]'
}

if [ "${1:-} ${2:-}" = "release create" ]; then
  tag="$3"
  shift 3
  pre=false
  assets='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo | --title) shift 2 ;;
      --notes-file) if [ -n "${FAKE_GH_NOTES:-}" ]; then cp "$2" "$FAKE_GH_NOTES"; fi; shift 2 ;;
      --prerelease) pre=true; shift ;;
      --*) shift ;;
      *)
        name="$(basename "$1")"
        digest="sha256:$(shasum -a 256 "$1" | awk '{print $1}')"
        if [ "$name" = "${FAKE_WRONG_DIGEST:-}" ]; then digest="sha256:$(printf 'f%.0s' $(seq 1 64))"; fi
        isnull=false
        if [ "$name" = "${FAKE_NULL_DIGEST:-}" ]; then isnull=true; fi
        assets="$(jq -c --arg n "$name" --arg d "$digest" --argjson z "$isnull" '. + [{name: $n, digest: (if $z then null else $d end)}]' <<<"$assets")"
        shift
        ;;
    esac
  done
  if [ "${FAKE_EXTRA_ASSET:-0}" = 1 ]; then
    assets="$(jq -c '. + [{name: "extra.bin", digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000"}]' <<<"$assets")"
  fi
  case "${FAKE_CREATE_FAIL:-0}" in
    nodraft) echo "HTTP 502: upload failed" >&2; exit 1 ;;
    1)
      add_release "$tag" true "$pre" "$(jq -c '.[:1]' <<<"$assets")"
      echo "HTTP 502: upload failed" >&2
      exit 1
      ;;
  esac
  draft=true
  if [ "${FAKE_CREATE_PUBLISHED:-0}" = 1 ]; then draft=false; fi
  add_release "$tag" "$draft" "$pre" "$assets"
  if [ "${FAKE_SECOND_DRAFT:-0}" = 1 ]; then add_release "$tag" true "$pre" "$assets"; fi
  echo "https://github.com/example/repo/releases/tag/untagged-0123456789abcdef"
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  shift
  method=GET
  include=0
  path=""
  fields=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -i) include=1; shift ;;
      --paginate) shift ;;
      -F | -f) fields+=("$2"); shift 2 ;;
      -*) echo "fake gh: unexpected api flag $1" >&2; exit 1 ;;
      *) path="$1"; shift ;;
    esac
  done
  if [ -n "${FAKE_API_FAIL:-}" ] && [[ "$method $path" == $FAKE_API_FAIL ]] && [ ! -e "$T.failed-once" ]; then
    if [ "${FAKE_API_FAIL_ONCE:-0}" = 1 ]; then : >"$T.failed-once"; fi
    if [ "$include" -eq 1 ]; then printf 'HTTP/2.0 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n'; fi
    echo "gh: Server Error (HTTP 500)" >&2
    exit 1
  fi
  case "$method $path" in
    "GET repos/example/repo/releases?per_page=100")
      if [ "${FAKE_LISTING_HIDES:-0}" = 1 ]; then echo '[]'; else cat "$T"; fi
      ;;
    "GET repos/example/repo/releases/tags/"*)
      rel="$(jq -c --arg t "${path##*/releases/tags/}" '[.[] | select(.tag_name == $t and .draft == false)][0] // empty' "$T")"
      if [ -n "$rel" ]; then
        if [ "$include" -eq 1 ]; then printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n'; fi
        echo "$rel"
        exit 0
      fi
      if [ "$include" -eq 1 ]; then printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n'; fi
      echo '{"message":"Not Found","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
      ;;
    "GET repos/example/repo/releases/"*)
      id="${path##*/}"
      n="$(bump "get-$id")"
      if [ -n "${FAKE_FLIP_ON_GET:-}" ] && [ "$n" -ge "$FAKE_FLIP_ON_GET" ]; then
        edit_table --argjson i "$id" 'map(if .id == $i then .draft = false else . end)'
      fi
      rel="$(jq -c --argjson i "$id" '[.[] | select(.id == $i)][0] // empty' "$T")"
      if [ -z "$rel" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
      echo "$rel"
      ;;
    "PATCH repos/example/repo/releases/"*)
      id="${path##*/}"
      upd='.'
      for kv in ${fields[@]+"${fields[@]}"}; do
        case "$kv" in
          draft=false) upd="$upd | .draft = false" ;;
          prerelease=true) upd="$upd | .prerelease = true" ;;
          make_latest=true) upd="$upd | .make_latest = \"true\"" ;;
          *) echo "fake gh: unexpected field $kv" >&2; exit 1 ;;
        esac
      done
      edit_table --argjson i "$id" "map(if .id == \$i then $upd else . end)"
      jq -c --argjson i "$id" '[.[] | select(.id == $i)][0] // {}' "$T"
      ;;
    "DELETE repos/example/repo/releases/"*)
      edit_table --argjson i "${path##*/}" 'map(select(.id != $i))'
      ;;
    *) echo "unexpected gh call: api $method $path" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
FAKE
chmod +x "$WORK/bin/gh"

# --- dist builders ---
add_pdfium_headers() { # <xcframework>: the layout the contract fixes (module map at the root, umbrella header one folder down)
  local d
  for d in "$1"/*/Headers; do
    mkdir -p "$d/PDFium"
    printf 'module PDFium {\n  umbrella header "PDFium/PDFium.h"\n  export *\n  link "c++"\n}\n' >"$d/module.modulemap"
    printf 'typedef int FPDF_FAKE;\n' >"$d/PDFium/PDFium.h"
  done
}
anchor_of() { # <engine name>: the symbol release-publish.sh requires that engine's archive to define (without the leading _)
  case "$1" in
    PDFium) echo FPDF_InitLibrary ;;
    QPDF) echo qpdf_init ;;
  esac
}
zip_framework() { # <dist dir> <name> <slice kinds...>
  local dist="$1" name="$2"
  shift 2
  # each engine gets its own symbol, as the real archives must (release-publish.sh refuses a shared one),
  # plus the anchor symbol the gate requires (FPDF_InitLibrary in PDFium, qpdf_init in QPDF)
  TINY_SYMBOL="qb_$name" TINY_EXTRA="$(anchor_of "$name")" tiny_framework "$WORK/build/$name.xcframework" yes "$@"
  if [ "$name" = "PDFium" ]; then add_pdfium_headers "$WORK/build/$name.xcframework"; fi
  rm -f "$dist/$name.xcframework.zip"
  ditto -c -k --keepParent "$WORK/build/$name.xcframework" "$dist/$name.xcframework.zip"
}
# Every notice the gate requires in a full release's LICENSES.zip (what scripts/licenses.sh assemble adds).
REQUIRED_NOTICES="README.txt pdfium/pdfium.txt pdfium/skia.txt pdfium/libyuv.txt pdfium/zlib.txt pdfium/freetype.txt
  pdfium-binaries/LICENSE embedpdf/LICENSE embedpdf/NOTICE qpdf/LICENSE.txt qpdf/NOTICE.md
  libjpeg-turbo/LICENSE.md libjpeg-turbo/README.ijg pdf-engine-builds/LICENSE pdf-engine-builds/NOTICE"
zip_licenses() { # <dist dir> [omit: a notice file to leave out, relative to LICENSES/] [empty: one to leave empty]
  local f
  rm -rf "$WORK/build/LICENSES"
  for f in $REQUIRED_NOTICES pdfium/icu.txt; do
    mkdir -p "$(dirname "$WORK/build/LICENSES/$f")"
    printf 'notice text of %s\n' "$f" >"$WORK/build/LICENSES/$f"
  done
  if [ -n "${2:-}" ]; then rm -f "$WORK/build/LICENSES/$2"; fi
  if [ -n "${3:-}" ]; then : >"$WORK/build/LICENSES/$3"; fi
  rm -f "$1/LICENSES.zip"
  (cd "$WORK/build" && ditto -c -k --keepParent LICENSES "$1/LICENSES.zip")
}
write_checksums() { # <dist dir> <asset names...>
  local dist="$1"
  shift
  "$REPO/scripts/checksums.sh" write "$dist" "$@" >/dev/null
}
full_dist() { # <dist dir>: a complete, correct release payload
  mkdir -p "$1"
  zip_framework "$1" PDFium mac ios sim
  zip_framework "$1" QPDF mac ios sim
  zip_licenses "$1"
  write_checksums "$1" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
}
TAG="v0.1.0-pdfium${PDFIUM_BRANCH#chromium/}"

RELEASES="$WORK/releases.json"
NOTES_COPY="$WORK/notes.md"
publish() { # <dist dir> <tag> [flags...]: runs the gate with the fake gh; sets $out and $code
  # The release table starts as $SEED (default: no releases); FAKE_* knobs pass through from the caller.
  local dist="$1" tag="$2"
  shift 2
  : >"$LOG"
  rm -f "$RELEASES".* "$NOTES_COPY"
  printf '%s\n' "${SEED:-[]}" >"$RELEASES"
  set +e
  out="$(DIST_DIR="$dist" GH_BIN="$WORK/bin/gh" RELEASE_REPO=example/repo FAKE_RELEASES="$RELEASES" FAKE_GH_NOTES="$NOTES_COPY" \
    "$REPO/scripts/release-publish.sh" "$tag" "$@" 2>&1)"
  code=$?
  set -e
}
no_create() { ! grep -q "release create" "$LOG"; }
# the gate never touches a release by its tag: no `gh release edit` or `gh release delete`
no_by_tag() { ! grep -qE "^release (edit|delete)" "$LOG"; }
no_patch() { ! grep -q -- "-X PATCH" "$LOG"; }
no_delete() { ! grep -q -- "-X DELETE" "$LOG"; }
deleted_by_id() { # <id>
  grep -qx "api -X DELETE repos/example/repo/releases/$1" "$LOG"
}
releases() { # <jq filter>: runs it over the release table the fake gh left behind
  jq -c "$1" "$RELEASES"
}
published_seed() { # <tag> <id>: a table holding one published release for the tag
  printf '[{"id":%s,"tag_name":"%s","draft":false,"prerelease":false,"assets":[]}]' "$2" "$1"
}
draft_seed() { # <tag> <id>: a table holding one leftover draft for the tag
  printf '[{"id":%s,"tag_name":"%s","draft":true,"prerelease":false,"assets":[]}]' "$2" "$1"
}

# === release-publish.sh ===
FULL="$WORK/full"
full_dist "$FULL"

publish "$FULL" "$TAG" --dry-run
check "dry run on a complete release exits 0 and never calls gh" $([ "$code" -eq 0 ] && [ ! -s "$LOG" ]; echo $?)

publish "$FULL" "$TAG"
check "a complete release publishes (exit 0)" $([ "$code" -eq 0 ] && grep -q "published $TAG to example/repo (release id 1)" <<<"$out"; echo $?)
check "before create, the gate lists the releases and looks the tag up (it must 404)" \
  $([ "$(sed -n 1p "$LOG")" = "api --paginate repos/example/repo/releases?per_page=100" ] \
    && [ "$(sed -n 2p "$LOG")" = "api -i repos/example/repo/releases/tags/$TAG" ] \
    && sed -n 3p "$LOG" | grep -q "^release create $TAG "; echo $?)
check "the draft was created with --verify-tag and as the latest release" $(grep "release create" "$LOG" | grep -q -- "--draft" && grep "release create" "$LOG" | grep -q -- "--verify-tag" && grep "release create" "$LOG" | grep -q -- "--latest"; echo $?)
missing_asset=0
for a in PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip checksums.txt; do
  grep "release create" "$LOG" | grep -q "$a" || missing_asset=1
done
check "all four assets were uploaded" "$missing_asset"
check "the draft is read back by its id, then published by its id with make_latest" \
  $(grep -qx "api repos/example/repo/releases/1" "$LOG" \
    && [ "$(tail -1 "$LOG")" = "api -X PATCH repos/example/repo/releases/1 -F draft=false -f make_latest=true" ]; echo $?)
check "the release table holds exactly one release for the tag, published" \
  $([ "$(releases "[.[] | select(.tag_name == \"$TAG\") | [.id, .draft, .make_latest]]")" = '[[1,false,"true"]]' ]; echo $?)
check "nothing was deleted, and nothing was addressed by its tag" $(no_delete && no_by_tag; echo $?)

# a published release already exists for the tag (a rerun after publishing): refuse before create, touch nothing
SEED="$(published_seed "$TAG" 7)" publish "$FULL" "$TAG"
check "a published release for the tag aborts before create (exit 1, names it)" \
  $([ "$code" -eq 1 ] && grep -q "already has a release or draft for $TAG" <<<"$out" && no_create && no_patch && no_delete; echo $?)
check "the published release is left exactly as it was" $([ "$(releases '.')" = "$(published_seed "$TAG" 7)" ]; echo $?)
# the same, when the listing does not show it (the tag lookup is the second, independent check)
SEED="$(published_seed "$TAG" 7)" FAKE_LISTING_HIDES=1 publish "$FULL" "$TAG"
check "a published release missing from the listing is still found by the tag lookup (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "already has a published release for $TAG" <<<"$out" && no_create && no_patch && no_delete; echo $?)
# a leftover draft (an earlier failed run whose cleanup failed): refuse, never publish or delete it
SEED="$(draft_seed "$TAG" 5)" publish "$FULL" "$TAG"
check "a leftover draft for the tag aborts before create (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "already has a release or draft for $TAG" <<<"$out" && no_create && no_patch && no_delete; echo $?)
check "the leftover draft is left for a person to inspect" $([ "$(releases '.')" = "$(draft_seed "$TAG" 5)" ]; echo $?)
# a release for another tag does not matter
SEED="$(published_seed v0.0.1-pdfium8100-stock-macos-only 3)" publish "$FULL" "$TAG"
check "a release for another tag does not block the release (exit 0)" \
  $([ "$code" -eq 0 ] && [ "$(releases '[.[] | [.id, .draft]]')" = '[[3,false],[4,false]]' ]; echo $?)

# GitHub cannot answer before create: any error that is not a 404 refuses
FAKE_API_FAIL="GET repos/example/repo/releases/tags/*" publish "$FULL" "$TAG"
check "a tag lookup failing with HTTP 500 aborts before create (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "could not confirm that $TAG has no published release" <<<"$out" && grep -q "HTTP status '500'" <<<"$out" && no_create; echo $?)
FAKE_API_FAIL="GET repos/example/repo/releases?per_page=100" publish "$FULL" "$TAG"
check "a failing releases listing aborts before create (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "could not list the releases of example/repo" <<<"$out" && no_create; echo $?)

# after create there must be exactly one release for the tag, and a draft
FAKE_SECOND_DRAFT=1 publish "$FULL" "$TAG"
check "two drafts for the tag after create: exit 7, nothing published or deleted" \
  $([ "$code" -eq 7 ] && grep -q "2 release(s) for $TAG instead of exactly one draft" <<<"$out" && no_patch && no_delete && no_by_tag; echo $?)
FAKE_CREATE_PUBLISHED=1 publish "$FULL" "$TAG"
check "a created release that is not a draft: exit 7, never deleted" \
  $([ "$code" -eq 7 ] && grep -q "instead of exactly one draft" <<<"$out" && no_patch && no_delete; echo $?)

# publishing fails: the draft stays for inspection, nothing else happens
FAKE_API_FAIL="PATCH *" publish "$FULL" "$TAG"
check "a failed publish exits 7 and leaves the draft (no delete)" \
  $([ "$code" -eq 7 ] && grep -q "could not publish the draft release $TAG (id 1)" <<<"$out" && no_delete \
    && [ "$(releases '[.[] | [.id, .draft]]')" = '[[1,true]]' ]; echo $?)

# a missing slice: the QPDF framework has no simulator slice
BAD="$WORK/missing-slice"
full_dist "$BAD"
zip_framework "$BAD" QPDF mac ios
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a missing slice aborts the release (exit 1, names the slices)" $([ "$code" -eq 1 ] && grep -q "slices differ" <<<"$out"; echo $?)
check "a missing slice never reaches gh release create" $(no_create; echo $?)

# a corrupted checksum
BAD="$WORK/corrupt"
full_dist "$BAD"
printf 'X' >>"$BAD/PDFium.xcframework.zip"
publish "$BAD" "$TAG"
check "a corrupted checksum aborts the release" $([ "$code" -eq 1 ] && grep -q "does not match the files" <<<"$out"; echo $?)
check "a corrupted checksum never reaches gh release create" $(no_create; echo $?)
publish "$BAD" "$TAG" --dry-run
check "the same corruption fails a dry run too" $([ "$code" -eq 1 ]; echo $?)

# a missing asset
BAD="$WORK/no-qpdf"
full_dist "$BAD"
rm "$BAD/QPDF.xcframework.zip"
publish "$BAD" "$TAG"
check "a missing asset aborts the release" $([ "$code" -eq 1 ] && no_create; echo $?)

# the exact asset set, past the checksum check: every line of checksums.txt verifies, but the set is wrong
BAD="$WORK/set-no-licenses"
full_dist "$BAD"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip
publish "$BAD" "$TAG"
check "a checksums.txt that omits LICENSES.zip aborts the release (exit 1, names both sets)" \
  $([ "$code" -eq 1 ] && grep -q "checksums.txt lists 'PDFium.xcframework.zip QPDF.xcframework.zip' but this release must contain exactly 'LICENSES.zip PDFium.xcframework.zip QPDF.xcframework.zip'" <<<"$out" && no_create; echo $?)
BAD="$WORK/set-extra-listed"
full_dist "$BAD"
printf 'extra' >"$BAD/extra.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip extra.zip
publish "$BAD" "$TAG"
check "an extra zip, listed in checksums.txt and present, aborts the release (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "checksums.txt lists 'LICENSES.zip PDFium.xcframework.zip QPDF.xcframework.zip extra.zip' but" <<<"$out" && no_create; echo $?)
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "an extra zip that checksums.txt does not list aborts the release (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "zip files in .* are 'LICENSES.zip PDFium.xcframework.zip QPDF.xcframework.zip extra.zip' but" <<<"$out" && no_create; echo $?)

# a framework zip without the module map
BAD="$WORK/no-modulemap"
full_dist "$BAD"
tiny_framework "$WORK/build/PDFium.xcframework" yes mac ios sim
rm -f "$BAD/PDFium.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/PDFium.xcframework" "$BAD/PDFium.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a PDFium framework without a module map aborts the release" $([ "$code" -eq 1 ] && grep -q "module.modulemap" <<<"$out" && no_create; echo $?)

# the old header layout: umbrella header named without its folder (the module map would warn
# -Wincomplete-umbrella beside qpdf's headers)
BAD="$WORK/old-layout"
full_dist "$BAD"
zip_framework "$BAD" PDFium mac ios sim
for d in "$WORK"/build/PDFium.xcframework/*/Headers; do
  printf 'module PDFium {\n  umbrella header "PDFium.h"\n  export *\n  link "c++"\n}\n' >"$d/module.modulemap"
done
rm -f "$BAD/PDFium.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/PDFium.xcframework" "$BAD/PDFium.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a module map whose umbrella header is not PDFium/PDFium.h aborts the release" $([ "$code" -eq 1 ] && grep -q 'umbrella header "PDFium/PDFium.h"' <<<"$out" && no_create; echo $?)

BAD="$WORK/root-umbrella"
full_dist "$BAD"
zip_framework "$BAD" PDFium mac ios sim
for d in "$WORK"/build/PDFium.xcframework/*/Headers; do
  cp "$d/PDFium/PDFium.h" "$d/PDFium.h"
done
rm -f "$BAD/PDFium.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/PDFium.xcframework" "$BAD/PDFium.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a PDFium.h left at the Headers root aborts the release" $([ "$code" -eq 1 ] && grep -q "Headers root" <<<"$out" && no_create; echo $?)

# PDFium and QPDF define the same symbol (two copies of one library, such as libjpeg)
BAD="$WORK/shared-symbol"
full_dist "$BAD"
TINY_SYMBOL=qb_PDFium TINY_EXTRA=qpdf_init tiny_framework "$WORK/build/QPDF.xcframework" yes mac ios sim
rm -f "$BAD/QPDF.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/QPDF.xcframework" "$BAD/QPDF.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a symbol defined by both PDFium and QPDF aborts the release" $([ "$code" -eq 1 ] && grep -q "both define 1 symbol(s) in slice" <<<"$out" && no_create; echo $?)

# nm fails on an archive: a tool error must refuse, never pass as "no symbol in common"
mkdir -p "$WORK/nm-fails" "$WORK/nm-silent"
printf '#!/usr/bin/env bash\necho "nm: error: cannot read this archive" >&2\nexit 1\n' >"$WORK/nm-fails/nm"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/nm-silent/nm"
chmod +x "$WORK/nm-fails/nm" "$WORK/nm-silent/nm"
PATH="$WORK/nm-fails:$PATH" publish "$FULL" "$TAG" --dry-run
check "a failing nm aborts the release (exit 1, names nm and the archive)" $([ "$code" -eq 1 ] && grep -q "nm failed on .*libtiny.a" <<<"$out" && ! grep -q "all checks passed" <<<"$out"; echo $?)
PATH="$WORK/nm-fails:$PATH" publish "$FULL" "$TAG"
check "a failing nm never reaches gh release create" $(no_create; echo $?)
# nm exits 0 but lists nothing: an empty definition list must refuse too
PATH="$WORK/nm-silent:$PATH" publish "$FULL" "$TAG" --dry-run
check "an nm that lists no definitions aborts the release (exit 1)" $([ "$code" -eq 1 ] && grep -q "nm lists no defined symbol in .*libtiny.a" <<<"$out"; echo $?)

# an archive without its engine's anchor symbol is not the engine it claims to be
BAD="$WORK/no-qpdf-anchor"
full_dist "$BAD"
TINY_SYMBOL=qb_QPDF tiny_framework "$WORK/build/QPDF.xcframework" yes mac ios sim
rm -f "$BAD/QPDF.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/QPDF.xcframework" "$BAD/QPDF.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG" --dry-run
check "a QPDF archive that does not define _qpdf_init aborts the release (exit 1)" $([ "$code" -eq 1 ] && grep -q "does not define _qpdf_init" <<<"$out"; echo $?)
BAD="$WORK/no-pdfium-anchor"
full_dist "$BAD"
TINY_SYMBOL=qb_PDFium tiny_framework "$WORK/build/PDFium.xcframework" yes mac ios sim
add_pdfium_headers "$WORK/build/PDFium.xcframework"
rm -f "$BAD/PDFium.xcframework.zip"
ditto -c -k --keepParent "$WORK/build/PDFium.xcframework" "$BAD/PDFium.xcframework.zip"
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG" --dry-run
check "a PDFium archive that does not define _FPDF_InitLibrary aborts the release (exit 1)" $([ "$code" -eq 1 ] && grep -q "does not define _FPDF_InitLibrary" <<<"$out"; echo $?)

# LICENSES.zip without the pdfium-binaries MIT text (the iOS patch header promises it)
BAD="$WORK/no-mit"
full_dist "$BAD"
zip_licenses "$BAD" pdfium-binaries/LICENSE
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a LICENSES.zip without pdfium-binaries/LICENSE aborts the release" $([ "$code" -eq 1 ] && grep -q "pdfium-binaries/LICENSE" <<<"$out" && no_create; echo $?)

# Skia's path code is linked into the patched libpdfium.a (patch 0002), so its notice must ship
BAD="$WORK/no-skia"
full_dist "$BAD"
zip_licenses "$BAD" pdfium/skia.txt
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG"
check "a LICENSES.zip without pdfium/skia.txt aborts the release (exit 1, names it)" $([ "$code" -eq 1 ] && grep -q "LICENSES.zip is missing LICENSES/pdfium/skia.txt" <<<"$out" && no_create; echo $?)
# every other required notice, one at a time (dry runs: nothing reaches gh either way)
for f in $REQUIRED_NOTICES; do
  [ "$f" = pdfium/skia.txt ] && continue
  zip_licenses "$BAD" "$f"
  write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
  publish "$BAD" "$TAG" --dry-run
  check "a LICENSES.zip without $f aborts the release" $([ "$code" -eq 1 ] && grep -q "LICENSES.zip is missing LICENSES/$f" <<<"$out"; echo $?)
done
zip_licenses "$BAD" "" embedpdf/NOTICE
write_checksums "$BAD" PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip
publish "$BAD" "$TAG" --dry-run
check "an empty embedpdf/NOTICE aborts the release" $([ "$code" -eq 1 ] && grep -q "LICENSES.zip is missing LICENSES/embedpdf/NOTICE" <<<"$out"; echo $?)

# a tag that does not match the pinned PDFium branch, and a malformed tag
publish "$FULL" "v0.1.0-pdfium9999"
check "a tag naming another PDFium branch than versions.env aborts the release (exit 3)" $([ "$code" -eq 3 ] && no_create; echo $?)
publish "$FULL" "release-1"
check "a malformed tag is a usage error" $([ "$code" -eq 2 ] && no_create; echo $?)

# GitHub reports a different checksum than the local file: the draft must be deleted by its id, not published
FAKE_WRONG_DIGEST=QPDF.xcframework.zip publish "$FULL" "$TAG"
check "a server-side checksum mismatch exits 6 and names the asset" $([ "$code" -eq 6 ] && grep -q "for QPDF.xcframework.zip but the local file" <<<"$out"; echo $?)
check "the draft release is deleted by its id and never published" \
  $(deleted_by_id 1 && no_patch && no_by_tag && [ "$(releases 'length')" = 0 ] && grep -q "deleted the draft release 1" <<<"$out"; echo $?)

# GitHub has no digest for an asset (null): that is a mismatch, never a pass
FAKE_NULL_DIGEST=LICENSES.zip publish "$FULL" "$TAG"
check "a null digest on the draft exits 6, deletes the draft by its id and never publishes" \
  $([ "$code" -eq 6 ] && grep -q "GitHub reports '...' for LICENSES.zip" <<<"$out" && deleted_by_id 1 && no_patch; echo $?)
# the draft holds an asset that was not uploaded
FAKE_EXTRA_ASSET=1 publish "$FULL" "$TAG"
check "an extra asset on the draft exits 6, deletes the draft by its id and never publishes" \
  $([ "$code" -eq 6 ] && grep -q "the draft release holds 5 assets but 4 were uploaded" <<<"$out" && deleted_by_id 1 && no_patch; echo $?)

# creating the draft fails half way: the partial draft (found by the tag, none existed before) is deleted by id
FAKE_CREATE_FAIL=1 publish "$FULL" "$TAG"
check "a failed draft creation exits 7 and deletes the partial draft by its id" \
  $([ "$code" -eq 7 ] && grep -q "could not create the draft release $TAG" <<<"$out" && deleted_by_id 1 && no_patch && no_by_tag \
    && [ "$(releases 'length')" = 0 ]; echo $?)
FAKE_CREATE_FAIL=nodraft publish "$FULL" "$TAG"
check "a draft creation that fails before any draft exists exits 7 and deletes nothing" \
  $([ "$code" -eq 7 ] && no_delete && no_patch && no_by_tag; echo $?)

# GitHub cannot read the draft back: delete it by its id (it is still a draft), never publish
FAKE_API_FAIL="GET repos/example/repo/releases/1" FAKE_API_FAIL_ONCE=1 publish "$FULL" "$TAG"
check "a failed read-back of the draft exits 6 and deletes the draft by its id" \
  $([ "$code" -eq 6 ] && grep -q "could not read the draft release 1 back" <<<"$out" && deleted_by_id 1 && no_patch; echo $?)

# the draft is published by someone else before the gate deletes it: the gate never deletes a release that is not a draft
FAKE_WRONG_DIGEST=QPDF.xcframework.zip FAKE_FLIP_ON_GET=2 publish "$FULL" "$TAG"
check "delete_draft refuses a release that is no longer a draft (exit 6, no DELETE)" \
  $([ "$code" -eq 6 ] && no_delete && grep -q "release 1 was not deleted" <<<"$out" && [ "$(releases '[.[] | [.id, .draft]]')" = '[[1,false]]' ]; echo $?)

# the macOS-only pre-release
MAC="$WORK/mac-only"
mkdir -p "$MAC"
zip_framework "$MAC" PDFium mac
write_checksums "$MAC" PDFium.xcframework.zip
MACTAG="v0.0.1-pdfium${PDFIUM_BRANCH#chromium/}-stock-macos-only"
publish "$MAC" "$MACTAG"
check "the macOS-only pre-release publishes as a pre-release, not as latest" $([ "$code" -eq 0 ] && grep "release create" "$LOG" | grep -q -- "--prerelease" && ! grep "release create" "$LOG" | grep -q -- "--latest"; echo $?)
check "the macOS-only pre-release is published by its id as a pre-release, without make_latest" \
  $([ "$(tail -1 "$LOG")" = "api -X PATCH repos/example/repo/releases/1 -F draft=false -F prerelease=true" ] \
    && [ "$(releases '[.[] | [.id, .draft, .prerelease]]')" = '[[1,false,true]]' ]; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "release-gate-test: $failures failure(s)"
  exit 1
fi
echo "release-gate-test: all passed"
