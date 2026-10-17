#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-patches-export.sh against a small fake "fork" repository built on the fly
# (an upstream commit and a fork commit on top of it). No network.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-patches-export.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-patches-export-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# --- the fake fork -------------------------------------------------------------------------------------------
FORK="$WORK/fork"
mkdir -p "$FORK" "$WORK/home"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git -C "$FORK" init -q -b main
git -C "$FORK" config uploadpack.allowFilter true
git -C "$FORK" config uploadpack.allowAnySHA1InWant true
gitf() { git -C "$FORK" -c commit.gpgsign=false "$@"; }
lines() { # <prefix> <count>: count lines "prefix N"
  local i=1
  while [ "$i" -le "$2" ]; do echo "$1 $i"; i=$((i + 1)); done
}
put() { # <path> then content on stdin
  mkdir -p "$FORK/$(dirname "$1")"
  cat >"$FORK/$1"
}

lines upstream 20 | put BUILD.gn
lines upstream 20 | put core/fpdfapi/parser/cpdf_document.cpp
lines upstream 20 | put core/fpdfdoc/cpdf_annot.cpp
lines upstream 20 | put core/fxcrt/fx_system.cpp
lines upstream 20 | put fpdfsdk/fpdf_save.cpp
lines upstream 20 | put fpdfsdk/fpdf_save_embeddertest.cpp
lines upstream 20 | put public/fpdfview.h
lines upstream 20 | put xfa/fgas/layout/fgas_linebreak.cpp
lines upstream 12 | put .gitignore
printf '\000\001\002\377\376base' | put testing/resources/base.bin
gitf add -A
gitf commit -q -m "upstream base"
U="$(gitf rev-parse HEAD)"

for f in BUILD.gn core/fpdfapi/parser/cpdf_document.cpp core/fpdfdoc/cpdf_annot.cpp core/fxcrt/fx_system.cpp \
  fpdfsdk/fpdf_save.cpp fpdfsdk/fpdf_save_embeddertest.cpp public/fpdfview.h .gitignore; do
  sed -i.bak '10s/.*/fork changed this line/' "$FORK/$f"
  rm "$FORK/$f.bak"
done
printf '\000\001\002\377\376base\000more' >"$FORK/testing/resources/base.bin"
rm "$FORK/xfa/fgas/layout/fgas_linebreak.cpp"
echo "// SPDX-License-Identifier: Apache-2.0" | put public/epdf_redact.h
echo "// new" | put fpdfsdk/epdf_redact.cpp
echo "// new" | put core/fpdfapi/edit/cpdf_text_redactor.cpp
echo "// new" | put core/fpdfapi/edit/cpdf_text_redactor_unittest.cpp
echo "// new" | put core/fpdfdoc/cpdf_cloudy_border.cpp
echo "// new" | put fpdfsdk/epdf_redact_embeddertest.cpp
printf '\000\377\000binary-fixture\000' | put testing/resources/redact.bin
echo "name: x" | put .github/workflows/x.yml
echo "echo hi" | put scripts/embedpdf-runtime/a.sh
printf 'diff --git a/gn/core.gni b/gn/core.gni\n--- a/gn/core.gni\n+++ b/gn/core.gni\n@@ -1 +1,2 @@\n a\n+b\n' | put patches/embedpdf-runtime/skia/geometry-only-stroke.patch
echo "CloudPDF notice" | put NOTICE
gitf add -A
gitf commit -q -m "fork changes"
F="$(gitf rev-parse HEAD)"

printf 'EMBEDPDF_REPO=file://%s\nEMBEDPDF_COMMIT=%s\nEMBEDPDF_UPSTREAM_BASE=%s\n' "$FORK" "$F" "$U" >"$WORK/versions.env"

# run <env assignments...> -- <script args...>: sets $out and $code
run() {
  local envs=() args=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; elif [ "$seen" -eq 0 ]; then envs+=("$a"); else args+=("$a"); fi
  done
  set +e
  out="$(env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="$WORK" WORK_DIR="$WORK/w" PATCH_OUT_DIR="$WORK/series" \
    VERSIONS_FILE="$WORK/versions.env" ${envs[@]+"${envs[@]}"} "$SCRIPT" ${args[@]+"${args[@]}"} 2>&1)"
  code=$?
  set -e
}
files_in() { grep -h '^diff --git a/' "$WORK/series/$1" | sed 's#^diff --git a/##; s# b/.*$##' | LC_ALL=C sort | tr '\n' ' '; }

# --- export ----------------------------------------------------------------------------------------------------
run --
check "export exits 0" $([ "$code" -eq 0 ]; echo $?)
check "0001-public-headers holds exactly the public headers" $([ "$(files_in 0001-public-headers.patch)" = "public/epdf_redact.h public/fpdfview.h " ]; echo $?)
check "0002-foundation holds build files, core/fxcrt and the xfa deletion" $([ "$(files_in 0002-foundation.patch)" = "BUILD.gn core/fxcrt/fx_system.cpp xfa/fgas/layout/fgas_linebreak.cpp " ]; echo $?)
check "0003-fpdfapi holds core/fpdfapi (non-test)" $([ "$(files_in 0003-fpdfapi.patch)" = "core/fpdfapi/edit/cpdf_text_redactor.cpp core/fpdfapi/parser/cpdf_document.cpp " ]; echo $?)
check "0004-fpdfdoc holds core/fpdfdoc" $([ "$(files_in 0004-fpdfdoc.patch)" = "core/fpdfdoc/cpdf_annot.cpp core/fpdfdoc/cpdf_cloudy_border.cpp " ]; echo $?)
check "0005-fpdfsdk holds fpdfsdk (non-test)" $([ "$(files_in 0005-fpdfsdk.patch)" = "fpdfsdk/epdf_redact.cpp fpdfsdk/fpdf_save.cpp " ]; echo $?)
check "0006-tests holds unit tests, embedder tests and testing/" \
  $([ "$(files_in 0006-tests.patch)" = "core/fpdfapi/edit/cpdf_text_redactor_unittest.cpp fpdfsdk/epdf_redact_embeddertest.cpp fpdfsdk/fpdf_save_embeddertest.cpp testing/resources/base.bin testing/resources/redact.bin " ]; echo $?)
check "0007 is the fork's Skia patch, to be applied inside third_party/skia" \
  $([ -f "$WORK/series/0007-skia-geometry-only-stroke.patch" ] && grep -qx '# Apply-Dir: third_party/skia' "$WORK/series/0007-skia-geometry-only-stroke.patch" && grep -q '^diff --git a/gn/core.gni' "$WORK/series/0007-skia-geometry-only-stroke.patch"; echo $?)
check "CI files, the fork's scripts and patches, NOTICE and .gitignore are listed as excluded and in no patch" \
  $([ "$(tr '\n' ' ' <"$WORK/series/EXCLUDED.txt")" = ".github/workflows/x.yml .gitignore NOTICE patches/embedpdf-runtime/skia/geometry-only-stroke.patch scripts/embedpdf-runtime/a.sh " ] && ! grep -lE 'workflows/x\.yml|a/NOTICE|a/\.gitignore|a/scripts/' "$WORK"/series/000[1-6]-*.patch >/dev/null 2>&1; echo $?)
headers_ok() {
  local p
  for p in "$WORK"/series/0*.patch; do
    head -12 "$p" | grep -q '^# Source: ' || return 1
    head -12 "$p" | grep -q '^# License: ' || return 1
    head -12 "$p" | grep -q '^# Apply-Dir: ' || return 1
  done
}
check "every patch starts with a provenance header (source, commits, group, license, apply dir)" $(headers_ok; echo $?)
check "the header records both pinned SHAs" $(grep -q "^# Source-Commit: $F" "$WORK/series/0003-fpdfapi.patch" && grep -q "^# Upstream-Base: $U" "$WORK/series/0003-fpdfapi.patch"; echo $?)
check "SOURCE.txt records the pins and one checksum line per patch" \
  $(grep -qx "source_commit=$F" "$WORK/series/SOURCE.txt" && grep -qx "upstream_base=$U" "$WORK/series/SOURCE.txt" && [ "$(grep -c '^patch=' "$WORK/series/SOURCE.txt")" -eq 7 ]; echo $?)

# --- the series reproduces the fork's tree (binary files included) ---------------------------------------------
git clone -q "$FORK" "$WORK/rt"
git -C "$WORK/rt" -c advice.detachedHead=false checkout -q "$U"
roundtrip=0
for p in "$WORK"/series/000[1-6]-*.patch; do
  git -C "$WORK/rt" apply "$p" || roundtrip=1
done
for f in $(grep -h '^diff --git a/' "$WORK"/series/000[1-6]-*.patch | sed 's#^diff --git a/##; s# b/.*$##'); do
  if git -C "$FORK" cat-file -e "$F:$f" 2>/dev/null; then
    git -C "$FORK" cat-file -p "$F:$f" | cmp -s - "$WORK/rt/$f" || roundtrip=1
  else
    [ ! -e "$WORK/rt/$f" ] || roundtrip=1
  fi
done
check "applying 0001-0006 to the upstream commit reproduces every included file of the fork, byte for byte" $([ "$roundtrip" -eq 0 ]; echo $?)

# --- determinism and --check -------------------------------------------------------------------------------------
# (the fallbacks only matter before the exporter exists: they keep this test running to its summary line)
cp -R "$WORK/series" "$WORK/series-first" 2>/dev/null || mkdir -p "$WORK/series" "$WORK/series-first"
run --
check "a second export is byte-identical to the first" $(diff -r "$WORK/series" "$WORK/series-first" >/dev/null; echo $?)
run -- --check
check "--check passes when the committed series matches the pins" $([ "$code" -eq 0 ] && grep -q "matches the pins" <<<"$out"; echo $?)
echo "# tampered" >>"$WORK/series/0003-fpdfapi.patch"
run -- --check
check "--check fails when a patch was edited by hand" $([ "$code" -eq 1 ] && grep -q "DIFFERS: 0003-fpdfapi.patch" <<<"$out"; echo $?)
run --
cp "$WORK/series-first/0003-fpdfapi.patch" "$WORK/series/0003-fpdfapi.patch" 2>/dev/null || true
: >"$WORK/series/0009-stale.patch"
run -- --check
check "--check fails when a stale patch is left in the series" $([ "$code" -eq 1 ] && grep -q "STALE (not produced by the pins): 0009-stale.patch" <<<"$out"; echo $?)
rm "$WORK/series/0009-stale.patch"

# --- bad pins leave the series untouched ---------------------------------------------------------------------
before="$(cat "$WORK"/series/*.patch | shasum -a 256)"
run EMBEDPDF_COMMIT=abc --
check "a malformed commit pin exits 2" $([ "$code" -eq 2 ]; echo $?)
run EMBEDPDF_UPSTREAM_BASE="$F" --
check "equal pins exit 2" $([ "$code" -eq 2 ]; echo $?)
run EMBEDPDF_UPSTREAM_BASE=0123456789abcdef0123456789abcdef01234567 --
check "a pin that does not exist upstream exits 4" $([ "$code" -eq 4 ]; echo $?)
run EMBEDPDF_COMMIT="$U" EMBEDPDF_UPSTREAM_BASE="$F" --
check "swapped pins exit 3 (the base must not carry the extension headers)" $([ "$code" -eq 3 ]; echo $?)
check "the series is untouched after every failed run" $([ "$(cat "$WORK"/series/*.patch | shasum -a 256)" = "$before" ]; echo $?)

run -- --nonsense
check "an unknown flag exits 2" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-patches-export-test: $failures failure(s)"; exit 1; fi
echo "pdfium-patches-export-test: all passed"
