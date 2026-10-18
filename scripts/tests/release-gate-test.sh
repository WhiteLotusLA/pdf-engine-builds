#!/usr/bin/env bash
# Self-test for scripts/release-publish.sh with a fake gh (no network); it uses scripts/checksums.sh from task A2.
# The release is all-or-nothing, so every case below that must NOT publish also asserts that the
# fake gh never saw `release create` (or, after a server-side mismatch, that the draft was deleted
# and `release edit` never ran).
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
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "release create") [ "${FAKE_CREATE_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
  "release edit") exit 0 ;;
  "release delete") exit 0 ;;
esac
if [ "$1" = "api" ]; then cat "$FAKE_RELEASES"; exit 0; fi
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
zip_licenses() { # <dist dir> [omit: a notice file to leave out, relative to LICENSES/]
  rm -rf "$WORK/build/LICENSES"
  mkdir -p "$WORK/build/LICENSES/pdfium" "$WORK/build/LICENSES/qpdf" "$WORK/build/LICENSES/pdfium-binaries"
  printf 'readme\n' >"$WORK/build/LICENSES/README.txt"
  printf 'pdfium license\n' >"$WORK/build/LICENSES/pdfium/pdfium.txt"
  printf 'qpdf license\n' >"$WORK/build/LICENSES/qpdf/LICENSE.txt"
  printf 'pdfium-binaries MIT\n' >"$WORK/build/LICENSES/pdfium-binaries/LICENSE"
  if [ -n "${2:-}" ]; then rm -f "$WORK/build/LICENSES/$2"; fi
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

listing() { # <dist dir> <tag> <draft true|false> [asset name whose digest is wrong]: JSON like GitHub's
  local dist="$1" tag="$2" draft="$3" wrong="${4:-}" f name digest rows=""
  for f in "$dist"/*; do
    name="$(basename "$f")"
    digest="sha256:$(shasum -a 256 "$f" | awk '{print $1}')"
    if [ "$name" = "$wrong" ]; then digest="sha256:$(printf 'f%.0s' $(seq 1 64))"; fi
    rows="$rows{\"name\":\"$name\",\"digest\":\"$digest\"},"
  done
  printf '[{"tag_name":"%s","draft":%s,"assets":[%s]}]\n' "$tag" "$draft" "${rows%,}"
}

publish() { # <dist dir> <tag> [flags...]: runs the gate with the fake gh; sets $out and $code
  local dist="$1" tag="$2"
  shift 2
  : >"$LOG"
  set +e
  out="$(DIST_DIR="$dist" GH_BIN="$WORK/bin/gh" RELEASE_REPO=example/repo FAKE_RELEASES="$WORK/releases.json" "$REPO/scripts/release-publish.sh" "$tag" "$@" 2>&1)"
  code=$?
  set -e
}
no_create() { ! grep -q "release create" "$LOG"; }

# === release-publish.sh ===
FULL="$WORK/full"
full_dist "$FULL"

publish "$FULL" "$TAG" --dry-run
check "dry run on a complete release exits 0 and never calls gh" $([ "$code" -eq 0 ] && [ ! -s "$LOG" ]; echo $?)

listing "$FULL" "$TAG" true >"$WORK/releases.json"
publish "$FULL" "$TAG"
check "a complete release publishes: draft first, then publish" $([ "$code" -eq 0 ] && head -1 "$LOG" | grep -q "release create $TAG" && tail -1 "$LOG" | grep -q "release edit $TAG --repo example/repo --draft=false"; echo $?)
check "the draft was created with --verify-tag and as the latest release" $(grep "release create" "$LOG" | grep -q -- "--draft" && grep "release create" "$LOG" | grep -q -- "--verify-tag" && grep "release create" "$LOG" | grep -q -- "--latest"; echo $?)
missing_asset=0
for a in PDFium.xcframework.zip QPDF.xcframework.zip LICENSES.zip checksums.txt; do
  grep "release create" "$LOG" | grep -q "$a" || missing_asset=1
done
check "all four assets were uploaded" "$missing_asset"
check "nothing was deleted on the happy path" $(! grep -q "release delete" "$LOG"; echo $?)

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

# a tag that does not match the pinned PDFium branch, and a malformed tag
publish "$FULL" "v0.1.0-pdfium9999"
check "a tag naming another PDFium branch than versions.env aborts the release (exit 3)" $([ "$code" -eq 3 ] && no_create; echo $?)
publish "$FULL" "release-1"
check "a malformed tag is a usage error" $([ "$code" -eq 2 ] && no_create; echo $?)

# GitHub reports a different checksum than the local file: the draft must be deleted, not published
listing "$FULL" "$TAG" true QPDF.xcframework.zip >"$WORK/releases.json"
publish "$FULL" "$TAG"
check "a server-side checksum mismatch exits 6" $([ "$code" -eq 6 ]; echo $?)
check "the draft release is deleted and never published" $(grep -q "release delete $TAG" "$LOG" && ! grep -q "release edit" "$LOG"; echo $?)

# creating the draft fails half way: the partial draft is deleted and nothing is published
listing "$FULL" "$TAG" true >"$WORK/releases.json"
FAKE_CREATE_FAIL=1 publish "$FULL" "$TAG"
check "a failed draft creation exits 7 and deletes whatever draft exists" $([ "$code" -eq 7 ] && grep -q "release delete $TAG" "$LOG" && ! grep -q "release edit" "$LOG"; echo $?)

# the macOS-only pre-release
MAC="$WORK/mac-only"
mkdir -p "$MAC"
zip_framework "$MAC" PDFium mac
write_checksums "$MAC" PDFium.xcframework.zip
MACTAG="v0.0.1-pdfium${PDFIUM_BRANCH#chromium/}-stock-macos-only"
listing "$MAC" "$MACTAG" true >"$WORK/releases.json"
publish "$MAC" "$MACTAG"
check "the macOS-only pre-release publishes as a pre-release, not as latest" $([ "$code" -eq 0 ] && grep "release create" "$LOG" | grep -q -- "--prerelease" && ! grep "release create" "$LOG" | grep -q -- "--latest"; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "release-gate-test: $failures failure(s)"
  exit 1
fi
echo "release-gate-test: all passed"
