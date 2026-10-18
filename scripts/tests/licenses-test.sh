#!/usr/bin/env bash
# Self-test for scripts/licenses.sh (no network, no build). Checks that:
#   - the committed notices are sound: legal/embedpdf/COMMIT equals EMBEDPDF_COMMIT in versions.env and
#     legal/embedpdf/LICENSE, legal/embedpdf/NOTICE and legal/pdfium-binaries/LICENSE are non-empty
#     (these need no Xcode, so they also run in the Linux lint job and a stale copy fails early)
#   - on a fake PDFium tree laid out the way GN writes it (a root build.ninja of target aliases and an "all"
#     rule, per-target obj/**/*.ninja files with the compile edges, and a stand-in for ninja -t inputs),
#     stage-pdfium copies the notice of every library the graph names or the pdfium target compiles: libyuv,
#     Skia (GN label //skia, sources under third_party/skia), header-only libraries that compile no object
#     of their own (dragonbox, fast_float), and the rest; the copies hold the notice text
#   - a test library that is only in the graph (googletest, test_fonts) is not staged, but fails the run when
#     the pdfium target compiles it
#   - an unknown library fails the run and is named, whether build.ninja names it or the pdfium target compiles
#     it under a label outside //third_party; an empty or uppercase name counts as unknown
#   - a build graph with no library, an empty build.ninja, a missing ninja, compiled Skia objects without a
#     Skia notice, a missing always-linked notice, or a missing notice file fail the run
#   - assemble writes README.txt, the notices and a zip, merges PDFium stage dirs with different library
#     sets, drops a stale dist/LICENSES file, adds EmbedPDF only when patches exist, refuses legal/embedpdf
#     copied from another commit, and refuses two stage dirs that disagree
#   - a notice file with a byte that is not valid UTF-8 does not break staging, whatever the locale
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
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

# --- the committed notices of this repository (every platform) ---
pinned_embedpdf="$(sed -n 's/^EMBEDPDF_COMMIT=//p' "$REPO/versions.env")"
check "legal/embedpdf/COMMIT equals EMBEDPDF_COMMIT in versions.env (refresh legal/embedpdf when the pin moves)" \
  $([ -n "$pinned_embedpdf" ] && [ -f "$REPO/legal/embedpdf/COMMIT" ] && [ "$(tr -d '[:space:]' <"$REPO/legal/embedpdf/COMMIT")" = "$pinned_embedpdf" ]; echo $?)
for f in legal/embedpdf/LICENSE legal/embedpdf/NOTICE legal/pdfium-binaries/LICENSE; do
  check "$f is non-empty" $([ -s "$REPO/$f" ]; echo $?)
done

if [ "$(uname -s)" != "Darwin" ]; then
  if [ "$failures" -gt 0 ]; then
    echo "licenses-test: $failures failure(s)"
    exit 1
  fi
  echo "licenses-test: committed notices ok; the staging checks are skipped (they need Xcode tools)"
  exit 0
fi

LIC="$REPO/scripts/licenses.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/licenses-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- a fake PDFium checkout: the notice files, and ninja where gclient sync puts it ---
SRC="$WORK/pdfium"
BUILD="$SRC/out/macos-arm64"
notice() { # <path under $SRC> <text>
  mkdir -p "$(dirname "$SRC/$1")"
  printf '%s\n' "$2" >"$SRC/$1"
}
mkdir -p "$SRC"
printf '// Copyright 2014 The PDFium Authors\n//\n// Redistribution and use in source and binary forms\n' >"$SRC/LICENSE"
notice third_party/abseil-cpp/LICENSE "fake abseil-cpp LICENSE: Apache License 2.0"
notice third_party/agg23/agg_array.h "$(printf '//----\n// Anti-Grain Geometry - Version 2.3\n\n// Copyright (C) 2002-2005 Maxim Shemanarev\n#ifndef AGG_ARRAY_INCLUDED\n#define AGG_ARRAY_INCLUDED')"
notice third_party/freetype/FTL.TXT "fake FreeType Project License"
notice third_party/harfbuzz/src/COPYING "fake HarfBuzz COPYING: Old MIT license"
notice third_party/icu/LICENSE "fake ICU LICENSE: UNICODE LICENSE V3"
notice third_party/lcms/include/lcms2.h "$(printf '//  Little Color Management System\n//  Copyright (c) 1998-2023 Marti Maria Saguer\n\n#ifndef _lcms2_H')"
notice third_party/libjpeg_turbo/LICENSE.md "fake libjpeg-turbo LICENSE.md: Modified (3-clause) BSD License"
notice third_party/libjpeg_turbo/README.ijg "fake libjpeg-turbo README.ijg: Independent JPEG Group"
notice third_party/libopenjpeg/openjpeg.c "$(printf '/*\n * The copyright in this software is being made available under the 2-clauses\n * BSD License\n */\n#include "opj_includes.h"')"
notice third_party/libpng/LICENSE "fake libpng LICENSE: PNG Reference Library License version 2"
notice third_party/libyuv/LICENSE "fake libyuv LICENSE: Copyright 2011 The LibYuv Project Authors"
notice third_party/zlib/zlib.h "$(printf '/* zlib.h -- interface\n   Copyright (C) 1995 Jean-loup Gailly\n*/\n#define ZLIB_H')"
notice third_party/skia/LICENSE "fake Skia LICENSE: Copyright (c) 2011 Google Inc."
notice third_party/dragonbox/src/LICENSE-Apache2-LLVM "fake dragonbox Apache-2.0 WITH LLVM-exception"
notice third_party/dragonbox/src/LICENSE-Boost "fake dragonbox Boost Software License"
notice third_party/fast_float/src/LICENSE-MIT "fake fast_float MIT License"

# A stand-in for "ninja -C <dir> -t inputs <target>" as ninja 1.12.1 implements it (src/ninja.cc, ToolInputs):
# every input of every non-phony edge the target depends on, transitively (explicit, implicit and order-only),
# sorted and unique. It reads the build files (build lines, subninja, $ line continuations) like ninja does.
mkdir -p "$SRC/third_party/ninja"
cat >"$SRC/third_party/ninja/ninja" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then
  echo "1.12.1 (test stand-in)"
  exit 0
fi
if [ "$#" -ne 5 ] || [ "$1" != -C ] || [ "$3" != -t ] || [ "$4" != inputs ]; then
  echo "ninja: error: the test stand-in only runs -C <dir> -t inputs <target>" >&2
  exit 1
fi
cd "$2"
awk -v target="$5" '
  function load(file, line, joined, p, outs, rest, n, parts, i, m, o, ins, rule) {
    joined = ""
    while ((getline line < file) > 0) {
      if (line ~ /\$$/) { joined = joined substr(line, 1, length(line) - 1); continue }
      line = joined line
      joined = ""
      if (line ~ /^subninja /) { load(substr(line, 10)); continue }
      if (line !~ /^build /) continue
      line = substr(line, 7)
      p = index(line, ": ")
      outs = substr(line, 1, p - 1)
      rest = substr(line, p + 2)
      n = split(rest, parts, / +/)
      rule = parts[1]
      ins = ""
      for (i = 2; i <= n; i++) if (parts[i] != "|" && parts[i] != "||" && parts[i] != "") ins = ins " " parts[i]
      m = split(outs, o, / +/)
      for (i = 1; i <= m; i++) if (o[i] != "|" && o[i] != "") { edge_ins[o[i]] = ins; edge_phony[o[i]] = (rule == "phony") }
    }
    close(file)
  }
  function visit(node, n, a, i) {
    if (!(node in edge_ins) || (node in seen)) return
    seen[node] = 1
    n = split(edge_ins[node], a, / +/)
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      visit(a[i])
      if (!edge_phony[node]) print a[i]
    }
  }
  BEGIN {
    load("build.ninja")
    if (!(target in edge_ins)) { print "ninja: error: unknown target '\''" target "'\''" > "/dev/stderr"; exit 1 }
    visit(target)
  }
' | sort -u
FAKE
chmod +x "$SRC/third_party/ninja/ninja"

# --- the build directory, in the shape gn gen writes it ---
mkdir -p "$BUILD"
# The root file: rules for regenerating itself, the toolchain, one alias per target and the "all" rule.
cat >"$BUILD/build.ninja" <<'NINJA'
ninja_required_version = 1.7.2

rule gn
  command = ../../buildtools/mac/gn --root=../.. -q --regeneration gen .
  pool = console
  description = Regenerating ninja files

build build.ninja.stamp: gn
  generator = 1
  depfile = build.ninja.d

build build.ninja: phony build.ninja.stamp
  generator = 1

subninja toolchain.ninja

build $:pdfium: phony obj/libembedpdf.a
build pdfium: phony obj/libembedpdf.a
build pdfium_unittests: phony ./pdfium_unittests
build core/fxcrt$:fxcrt: phony phony/core/fxcrt/fxcrt
build core/fxcrt: phony phony/core/fxcrt/fxcrt
build skia$:redaction_pathops: phony obj/skia/libredaction_pathops.a
build redaction_pathops: phony obj/skia/libredaction_pathops.a
build third_party$:fx_agg: phony phony/third_party/fx_agg
build fx_agg: phony phony/third_party/fx_agg
build third_party$:fx_freetype: phony phony/third_party/fx_freetype
build fx_freetype: phony phony/third_party/fx_freetype
build third_party$:fx_lcms2: phony phony/third_party/fx_lcms2
build fx_lcms2: phony phony/third_party/fx_lcms2
build third_party$:fx_libopenjpeg: phony phony/third_party/fx_libopenjpeg
build fx_libopenjpeg: phony phony/third_party/fx_libopenjpeg
build third_party$:jpeg: phony phony/third_party/jpeg
build third_party$:png: phony phony/third_party/png
build third_party/abseil-cpp/absl/base$:base: phony phony/third_party/abseil-cpp/absl/base/base
build third_party/dragonbox$:dragonbox: phony phony/third_party/dragonbox/dragonbox
build third_party/dragonbox: phony phony/third_party/dragonbox/dragonbox
build third_party/fast_float$:fast_float: phony phony/third_party/fast_float/fast_float
build third_party/fast_float: phony phony/third_party/fast_float/fast_float
build third_party/googletest$:gtest: phony obj/third_party/googletest/libgtest.a
build third_party/harfbuzz$:harfbuzz: phony obj/third_party/harfbuzz/libharfbuzz.a
build third_party/harfbuzz: phony obj/third_party/harfbuzz/libharfbuzz.a
build third_party/icu$:icudata: phony icudtl.dat
build third_party/icu$:icuuc: phony obj/third_party/icu/libicuuc.a
build third_party/libjpeg_turbo$:libjpeg: phony obj/third_party/libjpeg_turbo/libjpeg.a
build third_party/libpng$:libpng: phony obj/third_party/libpng/libpng.a
build third_party/libpng: phony obj/third_party/libpng/libpng.a
build third_party/libyuv$:libyuv_internal: phony obj/third_party/libyuv/libyuv_internal.a
build third_party/test_fonts$:test_fonts: phony test_fonts/NotoSans-Regular.ttf
build third_party/zlib$:chrome_zlib: phony obj/third_party/zlib/libchrome_zlib.a

build all: phony $
    obj/libembedpdf.a $
    ./pdfium_unittests $
    phony/core/fxcrt/fxcrt $
    obj/skia/libredaction_pathops.a $
    phony/third_party/fx_agg $
    phony/third_party/fx_freetype $
    phony/third_party/fx_lcms2 $
    phony/third_party/fx_libopenjpeg $
    phony/third_party/abseil-cpp/absl/base/base $
    phony/third_party/dragonbox/dragonbox $
    phony/third_party/fast_float/fast_float $
    obj/third_party/googletest/libgtest.a $
    obj/third_party/harfbuzz/libharfbuzz.a $
    icudtl.dat $
    obj/third_party/icu/libicuuc.a $
    obj/third_party/libjpeg_turbo/libjpeg.a $
    obj/third_party/libpng/libpng.a $
    obj/third_party/libyuv/libyuv_internal.a $
    test_fonts/NotoSans-Regular.ttf $
    obj/third_party/zlib/libchrome_zlib.a

default all
NINJA
# The toolchain: rules, and one subninja per target. Rule commands name files under third_party (the compiler)
# that are not inputs of any edge.
cat >"$BUILD/toolchain.ninja" <<'NINJA'
rule cc
  command = ../../third_party/llvm-build/Release+Asserts/bin/clang -MMD -MF ${out}.d ${defines} ${include_dirs} -c ${in} -o ${out}
  description = CC ${out}
  depfile = ${out}.d
  deps = gcc
rule cxx
  command = ../../third_party/llvm-build/Release+Asserts/bin/clang++ -MMD -MF ${out}.d ${defines} ${include_dirs} -c ${in} -o ${out}
  description = CXX ${out}
  depfile = ${out}.d
  deps = gcc
rule alink
  command = rm -f ${out} && libtool -static -no_warning_for_no_symbols -o ${out} ${in}
  description = AR ${out}
rule link
  command = ../../third_party/llvm-build/Release+Asserts/bin/clang++ -o ${out} ${in}
  description = LINK ${out}
rule copy
  command = ln -f ${in} ${out} 2>/dev/null || (rm -rf ${out} && cp -af ${in} ${out})
  description = COPY ${in} ${out}

subninja obj/core/fxcrt/fxcrt.ninja
subninja obj/skia/redaction_pathops.ninja
subninja obj/third_party/fx_agg.ninja
subninja obj/third_party/fx_freetype.ninja
subninja obj/third_party/fx_lcms2.ninja
subninja obj/third_party/fx_libopenjpeg.ninja
subninja obj/third_party/abseil-cpp/absl/base/base.ninja
subninja obj/third_party/dragonbox/dragonbox.ninja
subninja obj/third_party/fast_float/fast_float.ninja
subninja obj/third_party/googletest/gtest.ninja
subninja obj/third_party/harfbuzz/harfbuzz.ninja
subninja obj/third_party/icu/icudata.ninja
subninja obj/third_party/icu/icuuc.ninja
subninja obj/third_party/libjpeg_turbo/libjpeg.ninja
subninja obj/third_party/libpng/libpng.ninja
subninja obj/third_party/libyuv/libyuv_internal.ninja
subninja obj/third_party/test_fonts/test_fonts.ninja
subninja obj/third_party/zlib/chrome_zlib.ninja
subninja obj/pdfium.ninja
subninja obj/pdfium_unittests.ninja
NINJA
target_file() { # <file under the build dir> <content>
  mkdir -p "$(dirname "$BUILD/$1")"
  printf '%s\n' "$2" >"$BUILD/$1"
}
# PDFium's own code includes the header-only dragonbox and fast_float; they compile no object of their own.
target_file obj/core/fxcrt/fxcrt.ninja "defines = -DNDEBUG
include_dirs = -I../.. -Igen -I../../third_party/abseil-cpp -I../../third_party/dragonbox/src/include -I../../third_party/fast_float/src/include
build obj/core/fxcrt/fxcrt/fx_extension.o: cxx ../../core/fxcrt/fx_extension.cpp || phony/third_party/dragonbox/dragonbox phony/third_party/fast_float/fast_float
build phony/core/fxcrt/fxcrt: phony obj/core/fxcrt/fxcrt/fx_extension.o"
# EmbedPDF patch 0002: a target under //skia that compiles Skia's own sources.
target_file obj/skia/redaction_pathops.ninja "include_dirs = -I../.. -I../../third_party/skia
build obj/skia/redaction_pathops/SkPath.o: cxx ../../third_party/skia/src/core/SkPath.cpp
build obj/skia/libredaction_pathops.a: alink obj/skia/redaction_pathops/SkPath.o"
target_file obj/third_party/fx_agg.ninja "build obj/third_party/fx_agg/agg_curves.o: cxx ../../third_party/agg23/agg_curves.cpp
build phony/third_party/fx_agg: phony obj/third_party/fx_agg/agg_curves.o"
target_file obj/third_party/fx_freetype.ninja "build obj/third_party/fx_freetype/ftbase.o: cc ../../third_party/freetype/src/src/base/ftbase.c
build phony/third_party/fx_freetype: phony obj/third_party/fx_freetype/ftbase.o"
target_file obj/third_party/fx_lcms2.ninja "build obj/third_party/fx_lcms2/cmscnvrt.o: cc ../../third_party/lcms/src/cmscnvrt.c
build phony/third_party/fx_lcms2: phony obj/third_party/fx_lcms2/cmscnvrt.o"
target_file obj/third_party/fx_libopenjpeg.ninja "build obj/third_party/fx_libopenjpeg/openjpeg.o: cc ../../third_party/libopenjpeg/openjpeg.c
build phony/third_party/fx_libopenjpeg: phony obj/third_party/fx_libopenjpeg/openjpeg.o"
target_file obj/third_party/abseil-cpp/absl/base/base.ninja "build obj/third_party/abseil-cpp/absl/base/base/raw_logging.o: cxx ../../third_party/abseil-cpp/absl/base/internal/raw_logging.cc
build phony/third_party/abseil-cpp/absl/base/base: phony obj/third_party/abseil-cpp/absl/base/base/raw_logging.o"
target_file obj/third_party/dragonbox/dragonbox.ninja "build phony/third_party/dragonbox/dragonbox: phony"
target_file obj/third_party/fast_float/fast_float.ninja "build phony/third_party/fast_float/fast_float: phony"
target_file obj/third_party/googletest/gtest.ninja "include_dirs = -I../../third_party/googletest/src/googletest/include
build obj/third_party/googletest/gtest/gtest-all.o: cxx ../../third_party/googletest/src/googletest/src/gtest-all.cc
build obj/third_party/googletest/libgtest.a: alink obj/third_party/googletest/gtest/gtest-all.o"
target_file obj/third_party/harfbuzz/harfbuzz.ninja "build obj/third_party/harfbuzz/harfbuzz/hb-blob.o: cxx ../../third_party/harfbuzz/src/src/hb-blob.cc
build obj/third_party/harfbuzz/libharfbuzz.a: alink obj/third_party/harfbuzz/harfbuzz/hb-blob.o"
target_file obj/third_party/icu/icudata.ninja "build icudtl.dat: copy ../../third_party/icu/common/icudtl.dat"
target_file obj/third_party/icu/icuuc.ninja "build obj/third_party/icu/icuuc/uchar.o: cxx ../../third_party/icu/source/common/uchar.cpp
build obj/third_party/icu/libicuuc.a: alink obj/third_party/icu/icuuc/uchar.o"
target_file obj/third_party/libjpeg_turbo/libjpeg.ninja "build obj/third_party/libjpeg_turbo/libjpeg/jcapimin.o: cc ../../third_party/libjpeg_turbo/jcapimin.c
build obj/third_party/libjpeg_turbo/libjpeg.a: alink obj/third_party/libjpeg_turbo/libjpeg/jcapimin.o"
target_file obj/third_party/libpng/libpng.ninja "build obj/third_party/libpng/libpng/png.o: cc ../../third_party/libpng/png.c
build obj/third_party/libpng/libpng.a: alink obj/third_party/libpng/libpng/png.o"
target_file obj/third_party/libyuv/libyuv_internal.ninja "build obj/third_party/libyuv/libyuv_internal/convert_argb.o: cxx ../../third_party/libyuv/source/convert_argb.cc
build obj/third_party/libyuv/libyuv_internal.a: alink obj/third_party/libyuv/libyuv_internal/convert_argb.o"
target_file obj/third_party/test_fonts/test_fonts.ninja "build test_fonts/NotoSans-Regular.ttf: copy ../../third_party/test_fonts/test_fonts/NotoSans-Regular.ttf"
target_file obj/third_party/zlib/chrome_zlib.ninja "build obj/third_party/zlib/chrome_zlib/adler32.o: cc ../../third_party/zlib/adler32.c
build obj/third_party/zlib/libchrome_zlib.a: alink obj/third_party/zlib/chrome_zlib/adler32.o"
# //:pdfium, a complete static library: its own objects, every source_set object and every static library.
PDFIUM_LINK="build obj/libembedpdf.a: alink obj/core/fxcrt/fxcrt/fx_extension.o obj/third_party/fx_agg/agg_curves.o obj/third_party/fx_freetype/ftbase.o obj/third_party/fx_lcms2/cmscnvrt.o obj/third_party/fx_libopenjpeg/openjpeg.o obj/third_party/abseil-cpp/absl/base/base/raw_logging.o obj/skia/libredaction_pathops.a obj/third_party/harfbuzz/libharfbuzz.a obj/third_party/icu/libicuuc.a obj/third_party/libjpeg_turbo/libjpeg.a obj/third_party/libpng/libpng.a obj/third_party/libyuv/libyuv_internal.a obj/third_party/zlib/libchrome_zlib.a || icudtl.dat"
target_file obj/pdfium.ninja "$PDFIUM_LINK"
# A test executable: it links googletest and copies the test fonts; the pdfium target does neither.
target_file obj/pdfium_unittests.ninja "build ./pdfium_unittests: link obj/libembedpdf.a obj/third_party/googletest/libgtest.a || test_fonts/NotoSans-Regular.ttf"
# What the compile steps would leave behind.
mkdir -p "$BUILD/obj/skia/redaction_pathops" "$BUILD/obj/third_party/zlib/chrome_zlib"

# variant <name>: a copy of the build directory beside it, for a test that changes it.
variant() {
  rm -rf "$SRC/out/$1"
  cp -R "$BUILD" "$SRC/out/$1"
  echo "$SRC/out/$1"
}

export WORK_DIR="$WORK/work" DIST_DIR="$WORK/dist"

# --- stage-pdfium on the full graph ---
expect_exit "stage-pdfium succeeds on the GN-shaped build directory" 0 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage1"
S="$WORK/stage1/pdfium"
check "pdfium.txt has the comment markers stripped" $([ "$(head -1 "$S/pdfium.txt")" = "Copyright 2014 The PDFium Authors" ]; echo $?)
staged="$( (cd "$S" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ') 2>/dev/null || true)"
want="abseil.txt agg23.txt dragonbox-Apache2-LLVM.txt dragonbox-Boost.txt fast_float.txt freetype.txt harfbuzz.txt icu.txt lcms.txt libjpeg_turbo.ijg libjpeg_turbo.md libopenjpeg.txt libpng.txt libyuv.txt pdfium.txt skia.txt zlib.txt "
check "exactly the expected PDFium notices are staged (got: $staged)" $([ "$staged" = "$want" ]; echo $?)
check "the libyuv notice is libyuv's LICENSE" $(cmp -s "$SRC/third_party/libyuv/LICENSE" "$S/libyuv.txt"; echo $?)
check "the Skia notice is third_party/skia/LICENSE (target //skia:redaction_pathops)" $(cmp -s "$SRC/third_party/skia/LICENSE" "$S/skia.txt"; echo $?)
check "header-only dragonbox and fast_float notices are staged from the graph" $(cmp -s "$SRC/third_party/dragonbox/src/LICENSE-Boost" "$S/dragonbox-Boost.txt" && cmp -s "$SRC/third_party/dragonbox/src/LICENSE-Apache2-LLVM" "$S/dragonbox-Apache2-LLVM.txt" && cmp -s "$SRC/third_party/fast_float/src/LICENSE-MIT" "$S/fast_float.txt"; echo $?)
check "copied notices equal their sources (abseil, freetype, harfbuzz, icu, libjpeg_turbo, libpng)" $(cmp -s "$SRC/third_party/abseil-cpp/LICENSE" "$S/abseil.txt" && cmp -s "$SRC/third_party/freetype/FTL.TXT" "$S/freetype.txt" && cmp -s "$SRC/third_party/harfbuzz/src/COPYING" "$S/harfbuzz.txt" && cmp -s "$SRC/third_party/icu/LICENSE" "$S/icu.txt" && cmp -s "$SRC/third_party/libjpeg_turbo/LICENSE.md" "$S/libjpeg_turbo.md" && cmp -s "$SRC/third_party/libjpeg_turbo/README.ijg" "$S/libjpeg_turbo.ijg" && cmp -s "$SRC/third_party/libpng/LICENSE" "$S/libpng.txt"; echo $?)
check "notices cut from source headers hold the notice and nothing after it (agg23, lcms, libopenjpeg, zlib)" $(grep -q "Maxim Shemanarev" "$S/agg23.txt" && ! grep -q "#ifndef" "$S/agg23.txt" && grep -q "Marti Maria Saguer" "$S/lcms.txt" && ! grep -q "#ifndef" "$S/lcms.txt" && grep -q "2-clauses" "$S/libopenjpeg.txt" && ! grep -q "#include" "$S/libopenjpeg.txt" && grep -q "Jean-loup Gailly" "$S/zlib.txt" && ! grep -q "#define" "$S/zlib.txt"; echo $?)
check "an ignored test library (googletest) is not staged" $([ -z "$(find "$S" -iname '*googletest*')" ]; echo $?)
check "the test fonts are not staged" $([ -z "$(find "$S" -iname '*test_fonts*')" ]; echo $?)

# --- unknown or odd names fail the run and are named ---
V="$(variant unknown-graph)"
printf 'build third_party/mystery_lib$:mystery: phony phony/third_party/mystery_lib/mystery\n' >>"$V/build.ninja"
expect_exit "an unknown library in build.ninja fails the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names the unknown library" $(grep -q "unknown third_party library 'mystery_lib'" <<<"$out"; echo $?)

V="$(variant unknown-built)"
printf 'build obj/core/fxcrt/fxcrt/mystery.o: cxx ../../third_party/mystery_vendored/mystery.cc\n' >>"$V/obj/core/fxcrt/fxcrt.ninja"
printf '%s\n' "${PDFIUM_LINK/ || / obj/core/fxcrt/fxcrt/mystery.o || }" >"$V/obj/pdfium.ninja"
expect_exit "an unknown library compiled by a target outside //third_party fails the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names the library and says the pdfium target compiles it" $(grep -q "unknown third_party library 'mystery_vendored'" <<<"$out" && grep -q "ninja -t inputs pdfium" <<<"$out"; echo $?)

V="$(variant uppercase)"
printf 'build third_party/Skia2: phony obj/x\n' >>"$V/build.ninja"
expect_exit "a library name with an uppercase letter counts as unknown" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names it and the build.ninja line" $(grep -q "'Skia2'" <<<"$out" && grep -q "build third_party/Skia2: phony obj/x" <<<"$out"; echo $?)

V="$(variant empty-name)"
printf 'build third_party//odd: phony obj/y\n' >>"$V/build.ninja"
expect_exit "an empty library name counts as unknown" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure quotes the line" $(grep -q "build third_party//odd: phony obj/y" <<<"$out"; echo $?)

V="$(variant escaped-name)"
printf 'build third_party/zlib$ extra/x: phony obj/z\n' >>"$V/build.ninja"
expect_exit "a name holding a ninja escape (zlib\$ extra) is not cut down to a known name" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure quotes that line" $(grep -q 'build third_party/zlib\$ extra/x' <<<"$out"; echo $?)

V="$(variant ignored-but-built)"
printf '%s\n' "${PDFIUM_LINK/ || / obj/third_party/googletest/libgtest.a || }" >"$V/obj/pdfium.ninja"
expect_exit "an ignored library that the pdfium target compiles fails the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names googletest" $(grep -q "googletest" <<<"$out"; echo $?)

# --- detection that finds too little fails ---
V="$(variant empty)"
: >"$V/build.ninja"
expect_exit "an empty build.ninja fails the run" 2 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"

V="$(variant no-libraries)"
printf 'subninja toolchain.ninja\nbuild pdfium: phony obj/libembedpdf.a\n' >"$V/build.ninja"
printf 'rule alink\n  command = libtool -static -o ${out} ${in}\nrule cxx\n  command = clang++ -c ${in} -o ${out}\nsubninja obj/pdfium.ninja\n' >"$V/toolchain.ninja"
printf 'build obj/core/fxcrt/fxcrt/fx_extension.o: cxx ../../core/fxcrt/fx_extension.cpp\nbuild obj/libembedpdf.a: alink obj/core/fxcrt/fxcrt/fx_extension.o\n' >"$V/obj/pdfium.ninja"
rm -rf "$V/obj/skia"
expect_exit "a build graph that names no library fails the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure says the inputs show no zlib" $(grep -q "third_party/zlib" <<<"$out"; echo $?)

V="$(variant skia-objects-without-notice)"
printf '%s\n' "${PDFIUM_LINK/ obj\/skia\/libredaction_pathops.a/}" >"$V/obj/pdfium.ninja"
expect_exit "compiled Skia objects without a Skia notice fail the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names obj/skia and the Skia notice" $(grep -q "obj/skia" <<<"$out" && grep -q "Skia" <<<"$out"; echo $?)

V="$(variant no-harfbuzz)"
grep -v harfbuzz "$V/build.ninja" >"$V/build.ninja.new" && mv "$V/build.ninja.new" "$V/build.ninja"
printf '%s\n' "${PDFIUM_LINK/ obj\/third_party\/harfbuzz\/libharfbuzz.a/}" >"$V/obj/pdfium.ninja"
expect_exit "a missing always-linked notice (harfbuzz) fails the run" 1 "$LIC" stage-pdfium "$SRC" "$V" "$WORK/stage2"
check "the failure names harfbuzz.txt" $(grep -q "harfbuzz.txt" <<<"$out"; echo $?)

# --- missing files and tools ---
mv "$SRC/third_party/freetype/FTL.TXT" "$SRC/third_party/freetype/FTL.TXT.gone"
expect_exit "a known library with a missing notice file fails the run" 1 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage3"
check "the failure names the library and the missing file" $(grep -Eq "no notice file for (fx_)?freetype" <<<"$out" && grep -q "FTL.TXT" <<<"$out"; echo $?)
mv "$SRC/third_party/freetype/FTL.TXT.gone" "$SRC/third_party/freetype/FTL.TXT"

expect_exit "stage-pdfium with a missing build.ninja is a usage error" 2 "$LIC" stage-pdfium "$SRC" "$WORK/nowhere" "$WORK/stage4"

mv "$SRC/third_party/ninja/ninja" "$SRC/third_party/ninja/ninja.gone"
expect_exit "stage-pdfium without ninja is a tool error" 2 "$LIC" stage-pdfium "$SRC" "$BUILD" "$WORK/stage4"
check "the failure names where ninja was expected" $(grep -q "third_party/ninja/ninja" <<<"$out"; echo $?)
mv "$SRC/third_party/ninja/ninja.gone" "$SRC/third_party/ninja/ninja"

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

mkdir -p "$WORK/dist/LICENSES/pdfium"
printf 'left over from an earlier run\n' >"$WORK/dist/LICENSES/pdfium/stale.txt"
expect_exit "assemble without EmbedPDF patches succeeds" 0 "$FLIC" assemble "$WORK/stage1"
check "LICENSES.zip and README.txt exist" $([ -f "$WORK/dist/LICENSES.zip" ] && [ -f "$WORK/dist/LICENSES/README.txt" ]; echo $?)
check "no EmbedPDF notices without patches, and the README says so" $([ ! -d "$WORK/dist/LICENSES/embedpdf" ] && grep -q "Built without the EmbedPDF patch series" "$WORK/dist/LICENSES/README.txt"; echo $?)
check "every component folder is present" $([ -f "$WORK/dist/LICENSES/pdfium/pdfium.txt" ] && [ -f "$WORK/dist/LICENSES/qpdf/NOTICE.md" ] && [ -f "$WORK/dist/LICENSES/pdfium-binaries/LICENSE" ] && [ -f "$WORK/dist/LICENSES/pdf-engine-builds/NOTICE" ]; echo $?)
zip_listing="$(unzip -l "$WORK/dist/LICENSES.zip")"
check "the zip carries pdfium-binaries/LICENSE (the iOS patch header promises it)" $(grep -q 'LICENSES/pdfium-binaries/LICENSE$' <<<"$zip_listing"; echo $?)
check "the zip carries the Skia, libyuv, zlib and freetype notices" $(grep -q 'LICENSES/pdfium/skia.txt$' <<<"$zip_listing" && grep -q 'LICENSES/pdfium/libyuv.txt$' <<<"$zip_listing" && grep -q 'LICENSES/pdfium/zlib.txt$' <<<"$zip_listing" && grep -q 'LICENSES/pdfium/freetype.txt$' <<<"$zip_listing"; echo $?)
check "a stale file in dist/LICENSES from an earlier run is gone, also from the zip" $([ ! -e "$WORK/dist/LICENSES/pdfium/stale.txt" ] && ! grep -q 'stale.txt' <<<"$zip_listing"; echo $?)

# Two PDFium stage dirs (for example macOS and iOS) with different library sets: the release gets the union.
mkdir -p "$WORK/stage-ios/pdfium"
cp "$WORK/stage1/pdfium/pdfium.txt" "$WORK/stage1/pdfium/zlib.txt" "$WORK/stage-ios/pdfium/" \
  || check "the macOS stage dir has pdfium.txt and zlib.txt to copy" 1
printf 'a notice only the iOS graph needs\n' >"$WORK/stage-ios/pdfium/ios-only.txt"
expect_exit "assemble merges PDFium stage dirs with different library sets" 0 "$FLIC" assemble "$WORK/stage1" "$WORK/stage-ios"
check "the merged notices are the union of both sets" $(cmp -s "$WORK/stage-ios/pdfium/ios-only.txt" "$WORK/dist/LICENSES/pdfium/ios-only.txt" && cmp -s "$WORK/stage1/pdfium/skia.txt" "$WORK/dist/LICENSES/pdfium/skia.txt"; echo $?)

: >"$FAKE/patches/embedpdf/0001-example.patch"
expect_exit "assemble with patches adds the EmbedPDF notices" 0 "$FLIC" assemble "$WORK/stage1"
check "EmbedPDF notices are included" $(cmp -s "$FAKE/legal/embedpdf/LICENSE" "$WORK/dist/LICENSES/embedpdf/LICENSE" && cmp -s "$FAKE/legal/embedpdf/NOTICE" "$WORK/dist/LICENSES/embedpdf/NOTICE"; echo $?)

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
