#!/usr/bin/env bash
# Self-test for scripts/licenses.sh on a fake PDFium tree (no network, no build). Checks that:
#   - the notices of the libraries named in build.ninja are copied, ignored ones are not
#   - a library the script does not know fails the run and is named
#   - a known library whose notice file is missing fails the run and is named
#   - assemble writes README.txt, the notices and a zip, adds EmbedPDF only when patches exist,
#     refuses legal/embedpdf copied from another commit, and refuses two stage dirs that disagree
#   - a notice file with a byte that is not valid UTF-8 does not break staging, whatever the locale
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "licenses-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
LIC="$REPO/scripts/licenses.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/licenses-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
out=""
expect_exit() { # <label> <expected code> <command...>
  local label="$1" want="$2" got=0
  shift 2
  out="$("$@" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then echo "ok:   $label"; else echo "FAIL: $label (exit $got, wanted $want)"; failures=$((failures + 1)); fi
}

# --- a fake PDFium checkout and build directory ---
SRC="$WORK/pdfium"
BUILD="$WORK/pdfium/out"
mkdir -p "$SRC/third_party/abseil-cpp" "$SRC/third_party/freetype" "$SRC/third_party/zlib" "$BUILD"
printf '// Copyright 2014 The PDFium Authors\n//\n// Redistribution and use in source and binary forms\n' >"$SRC/LICENSE"
printf 'Apache License fake text\n' >"$SRC/third_party/abseil-cpp/LICENSE"
printf 'FreeType License fake text\n' >"$SRC/third_party/freetype/FTL.TXT"
printf '/* zlib.h -- interface\n   Copyright (C) 1995 Jean-loup Gailly\n*/\n#define ZLIB_H\n' >"$SRC/third_party/zlib/zlib.h"
cat >"$BUILD/build.ninja" <<'NINJA'
build obj/third_party/abseil-cpp/a.o: cxx ../../third_party/abseil-cpp/a.cc
build obj/third_party/freetype/b.o: cxx ../../third_party/freetype/b.c
build obj/third_party/zlib/c.o: cc ../../third_party/zlib/c.c
build obj/third_party/googletest/d.o: cxx ../../third_party/googletest/d.cc
NINJA

export WORK_DIR="$WORK/work" DIST_DIR="$WORK/dist"

# --- stage-pdfium ---
expect_exit "stage-pdfium succeeds on a known set" 0 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage1"
check "pdfium.txt has the comment markers stripped" $([ "$(head -1 "$WORK/stage1/pdfium/pdfium.txt")" = "Copyright 2014 The PDFium Authors" ]; echo $?)
check "abseil, freetype and zlib notices are staged" $([ -f "$WORK/stage1/pdfium/abseil.txt" ] && [ -f "$WORK/stage1/pdfium/freetype.txt" ] && grep -q "zlib.h" "$WORK/stage1/pdfium/zlib.txt"; echo $?)
check "an ignored test library (googletest) is not staged" $([ -z "$(ls "$WORK/stage1/pdfium" | grep -i googletest || true)" ]; echo $?)

printf 'build obj/third_party/mystery_lib/e.o: cxx ../../third_party/mystery_lib/e.cc\n' >>"$BUILD/build.ninja"
expect_exit "an unknown third_party library fails the run" 1 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage2"
check "the failure names the unknown library" $(grep -q "mystery_lib" <<<"$out"; echo $?)
grep -v mystery_lib "$BUILD/build.ninja" >"$BUILD/build.ninja.new" && mv "$BUILD/build.ninja.new" "$BUILD/build.ninja"

mv "$SRC/third_party/freetype/FTL.TXT" "$SRC/third_party/freetype/FTL.TXT.gone"
expect_exit "a known library with a missing notice file fails the run" 1 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage3"
check "the failure names the library and the missing file" $(grep -q "freetype" <<<"$out" && grep -q "FTL.TXT" <<<"$out"; echo $?)
mv "$SRC/third_party/freetype/FTL.TXT.gone" "$SRC/third_party/freetype/FTL.TXT"

expect_exit "stage-pdfium with a missing build.ninja is a usage error" 2 "$LIC" stage-pdfium "$SRC" "$WORK/nowhere" "$WORK/stage4"

# --- a notice with a byte that is not valid UTF-8 (Latin-1 names occur in real third_party headers) ---
printf '/* zlib.h -- interface\n   Copyright (C) 1995 Jean-loup Gailly, Andr\351\n*/\n#define ZLIB_H\n' >"$SRC/third_party/zlib/zlib.h"
expect_exit "a Latin-1 byte in a notice does not break staging, even in a UTF-8 locale" 0 env LC_ALL=en_US.UTF-8 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage-latin1"
check "the Latin-1 notice was staged whole" $(grep -q "Gailly" "$WORK/stage-latin1/pdfium/zlib.txt"; echo $?)
printf '/* zlib.h -- interface\n   Copyright (C) 1995 Jean-loup Gailly\n*/\n#define ZLIB_H\n' >"$SRC/third_party/zlib/zlib.h"

# --- stage-qpdf and assemble in a fake copy of the repo ---
FAKE="$WORK/repo"
mkdir -p "$FAKE/scripts" "$FAKE/legal/pdfium-binaries" "$FAKE/legal/embedpdf" "$FAKE/patches/embedpdf"
cp "$REPO/scripts/common.sh" "$REPO/scripts/licenses.sh" "$FAKE/scripts/"
cat >"$FAKE/versions.env" <<'ENV'
PDFIUM_BRANCH=chromium/9999
EMBEDPDF_REPO=https://github.com/embedpdf/runtime
EMBEDPDF_COMMIT=1111111111111111111111111111111111111111
EMBEDPDF_UPSTREAM_BASE=2222222222222222222222222222222222222222
QPDF_VERSION=1.2.3
LIBJPEG_TURBO_VERSION=4.5.6
MACOS_MIN=27.0
IOS_MIN=27.0
DEPOT_TOOLS_COMMIT=3333333333333333333333333333333333333333
ENV
printf 'Apache-2.0 text of this repo\n' >"$FAKE/LICENSE"
printf 'NOTICE of this repo\n' >"$FAKE/NOTICE"
printf 'MIT text of pdfium-binaries\n' >"$FAKE/legal/pdfium-binaries/LICENSE"
printf 'EmbedPDF LICENSE text\n' >"$FAKE/legal/embedpdf/LICENSE"
printf 'EmbedPDF NOTICE text\n' >"$FAKE/legal/embedpdf/NOTICE"
printf '1111111111111111111111111111111111111111\n' >"$FAKE/legal/embedpdf/COMMIT"
mkdir -p "$WORK/work/src/qpdf-1.2.3" "$WORK/work/src/libjpeg-turbo-4.5.6"
printf 'qpdf license\n' >"$WORK/work/src/qpdf-1.2.3/LICENSE.txt"
printf 'qpdf notice\n' >"$WORK/work/src/qpdf-1.2.3/NOTICE.md"
printf 'jpeg license\n' >"$WORK/work/src/libjpeg-turbo-4.5.6/LICENSE.md"
printf 'jpeg ijg\n' >"$WORK/work/src/libjpeg-turbo-4.5.6/README.ijg"
FLIC="$FAKE/scripts/licenses.sh"

expect_exit "stage-qpdf succeeds" 0 "$FLIC" stage-qpdf "$WORK/stage1"
check "qpdf and libjpeg-turbo notices are staged" $([ -f "$WORK/stage1/qpdf/LICENSE.txt" ] && [ -f "$WORK/stage1/libjpeg-turbo/README.ijg" ]; echo $?)

expect_exit "assemble without EmbedPDF patches succeeds" 0 "$FLIC" assemble "$WORK/stage1"
check "LICENSES.zip and README.txt exist" $([ -f "$WORK/dist/LICENSES.zip" ] && [ -f "$WORK/dist/LICENSES/README.txt" ]; echo $?)
check "no EmbedPDF notices without patches, and the README says so" $([ ! -d "$WORK/dist/LICENSES/embedpdf" ] && grep -q "Built without the EmbedPDF patch series" "$WORK/dist/LICENSES/README.txt"; echo $?)
check "every component folder is present" $([ -f "$WORK/dist/LICENSES/pdfium/pdfium.txt" ] && [ -f "$WORK/dist/LICENSES/qpdf/NOTICE.md" ] && [ -f "$WORK/dist/LICENSES/pdfium-binaries/LICENSE" ] && [ -f "$WORK/dist/LICENSES/pdf-engine-builds/NOTICE" ]; echo $?)
zip_listing="$(unzip -l "$WORK/dist/LICENSES.zip")"
check "the zip carries pdfium-binaries/LICENSE (the iOS patch header promises it)" $(grep -q 'LICENSES/pdfium-binaries/LICENSE$' <<<"$zip_listing"; echo $?)

: >"$FAKE/patches/embedpdf/0001-example.patch"
expect_exit "assemble with patches adds the EmbedPDF notices" 0 "$FLIC" assemble "$WORK/stage1"
check "EmbedPDF notices are included" $([ -f "$WORK/dist/LICENSES/embedpdf/LICENSE" ] && [ -f "$WORK/dist/LICENSES/embedpdf/NOTICE" ]; echo $?)

printf '9999999999999999999999999999999999999999\n' >"$FAKE/legal/embedpdf/COMMIT"
expect_exit "assemble refuses EmbedPDF notices copied from another commit" 1 "$FLIC" assemble "$WORK/stage1"
check "the failure says to refresh them" $(grep -q "refresh it" <<<"$out"; echo $?)
printf '1111111111111111111111111111111111111111\n' >"$FAKE/legal/embedpdf/COMMIT"

mkdir -p "$WORK/stage-other/pdfium"
printf 'different\n' >"$WORK/stage-other/pdfium/pdfium.txt"
expect_exit "assemble refuses stage dirs that disagree about a file" 1 "$FLIC" assemble "$WORK/stage1" "$WORK/stage-other"
expect_exit "assemble refuses a stage dir without qpdf notices" 1 "$FLIC" assemble "$WORK/stage-other"

if [ "$failures" -gt 0 ]; then
  echo "licenses-test: $failures failure(s)"
  exit 1
fi
echo "licenses-test: all passed"
