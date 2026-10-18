#!/usr/bin/env bash
# Usage:
#   scripts/licenses.sh stage-pdfium <pdfium source dir> <ninja build dir> <stage dir>
#       Copies the notice of PDFium and of every third_party library that the GN graph names
#       (build.ninja) or that the pdfium target compiles (ninja -t inputs pdfium) into
#       <stage dir>/pdfium/. A library this script does not know fails the run, so a new upstream
#       dependency is reviewed before it ships; so do a missing notice file, an ignored library the
#       pdfium target compiles, compiler-rt code from the clang package in the built library
#       (CLANG_RT_RE), compiled Skia objects without a Skia notice, and a missing notice of a library
#       every PDFium build links (REQUIRED_PDFIUM_NOTICES). Every unknown name (with one example),
#       missing notice file and compiled ignored library is listed before the run stops, so one build
#       shows the whole set.
#       ninja is the one PDFium's DEPS installs (<pdfium source dir>/third_party/ninja/ninja),
#       or NINJA_BIN.
#   scripts/licenses.sh stage-qpdf <stage dir>
#       Copies the qpdf and libjpeg-turbo notices from the unpacked sources in $WORK_DIR/src
#       into <stage dir>/qpdf/ and <stage dir>/libjpeg-turbo/.
#   scripts/licenses.sh assemble <stage dir>...
#       Merges the stage dirs, adds the committed notices in legal/ and this repo's own LICENSE
#       and NOTICE, writes dist/LICENSES/ with a README.txt, and zips it to dist/LICENSES.zip.
#
# Environment (optional): WORK_DIR, DIST_DIR, RELEASE_TAG (shown in README.txt), NINJA_BIN.
# Exit codes: 0 ok, 1 a notice is missing, unknown or stale, 2 usage or tool missing.
set -euo pipefail

# Notice files may hold bytes that are not valid UTF-8 (names in Latin-1); sed in a UTF-8 locale
# stops at the first one. Read everything as bytes.
export LC_ALL=C

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

# The target scripts/pdfium-build.sh builds (ninja -C out/<slice> pdfium): its inputs are what libpdfium.a
# is made of.
PDFIUM_NINJA_TARGET=pdfium

# Names that build.ninja lists but that are never linked into libpdfium.a: test code, build tools, and
# Chromium's libc++ (pdfium-build.sh sets use_custom_libcxx = false, so the SDK's libc++ is used). They are
# skipped only when they come from build.ninja: a library whose sources the pdfium target compiles always
# needs a notice, ignored or not.
IGNORED_THIRD_PARTY=" nasm googletest test_fonts libc++ libc++abi "

# Notices every PDFium build must carry: the libraries compiled into all four PDFium jobs of build run
# 39083399705 (stock macOS and the three patched slices; obj/third_party/<name> in their logs). One missing
# means the detection read the wrong build directory or PDFium's dependencies changed; review the list then.
REQUIRED_PDFIUM_NOTICES="abseil.txt agg23.txt freetype.txt harfbuzz.txt icu.txt lcms.txt libjpeg_turbo.md libopenjpeg.txt libyuv.txt zlib.txt"

# third_party/llvm-build is the clang package PDFium's DEPS pins: a toolchain, not a library. One file of it is an
# input of the pdfium target without being linked into it. //build/config/compiler:runtime_library adds
# //build/config/clang:compiler_builtins to every target, whose libs name compiler-rt's builtins archive
# (lib/clang/<version>/lib/darwin/libclang_rt.osx.a, .ios.a or .iossim.a by slice). GN writes a lib given as a
# path as an implicit dependency (after '|') of the link edge, and the Apple toolchain's alink archives only the
# explicit inputs (rspfile_content = "{{inputs}}" in build/toolchain/apple/toolchain.gni), so libtool never
# reads the archive; ninja -t inputs lists implicit inputs too. Build run 39094176013 shows it: the libpdfium.a
# of the macos-arm64, ios-arm64 and iossim-arm64 slices holds 1241 objects, none named after a compiler-rt source
# (os_version_check, udivti3 and the like), defines no external symbol starting with ___ (most builtins'
# names do) and none of the 289 that Xcode's own libclang_rt.osx.a defines, and leaves ___udivti3 and ___floattidf
# undefined for the app's toolchain to supply at the app's link. So that one archive needs no notice, but only
# while nm shows that the library built here defines none of its symbols (compiler_rt_not_linked); any other
# llvm-build file is unknown.
CLANG_RT_RE="^'?(\.\./)+third_party/llvm-build/Release[+]Asserts/lib/clang/[0-9]+/lib/darwin/libclang_rt[.](osx|ios|iossim)[.]a'?\$"

copy_notice() { # <library> <source file> <destination file>
  [ -f "$2" ] || die 1 "no notice file for $1: expected $2"
  cp "$2" "$3"
}

# Problems stage_pdfium meets while it reads the library names: an unknown name, a missing notice file, an ignored
# library that the pdfium target compiles. note_problem <key> <message> notes each once per key (the name, or the
# notice file it expected, whichever name of the library led there) and the read goes on. stage_die prints them all
# before the run stops, whichever check stops it, so one build shows the whole set.
PROBLEM_KEYS=$'\n'
PROBLEMS=""
note_problem() {
  case "$PROBLEM_KEYS" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  PROBLEM_KEYS="$PROBLEM_KEYS$1"$'\n'
  PROBLEMS="$PROBLEMS$2"$'\n'
}

# stage_die <exit code> <message>: die, after printing every problem noted so far and counting the unknown names.
stage_die() {
  local unknown
  if [ -n "$PROBLEMS" ]; then
    printf '%s' "$PROBLEMS" | awk -v name="$SCRIPT_NAME" '{ print name ": error: " $0 }' >&2
    unknown="$(printf '%s' "$PROBLEM_KEYS" | grep -c '^unknown ' || true)"
    if [ "$unknown" -gt 0 ]; then
      printf '%s: error: %s\n' "$SCRIPT_NAME" "the PDFium build uses $unknown third_party name(s) that scripts/licenses.sh does not know (each listed above with one example): for each, read third_party/<name> in the PDFium checkout, then add a case to stage_pdfium (or, for a test or build tool that the $PDFIUM_NINJA_TARGET target does not compile, to IGNORED_THIRD_PARTY) in scripts/licenses.sh" >&2
    fi
  fi
  die "$@"
}

# unknown_library <name> <where it was found> <the line>: notes a library this script does not know, with the first
# line that named it.
unknown_library() {
  note_problem "unknown $1" "unknown third_party library '$1' in the PDFium build ($2: ${3:0:200})"
}

# pdfium_notice <library> <source file> <destination file>: copy_notice for stage_pdfium, which notes a missing
# file instead of stopping.
pdfium_notice() {
  if [ -f "$2" ]; then
    cp "$2" "$3"
  else
    note_problem "notice $2" "no notice file for $1: expected $2"
  fi
}

# cut_notice <library> <source file> <destination file> <sed arguments...>: a notice cut out of a source header by
# sed; a missing header is noted like a missing notice file.
cut_notice() {
  local lib="$1" from="$2" to="$3"
  shift 3
  if [ -f "$from" ]; then
    sed "$@" "$from" >"$to"
  else
    note_problem "notice $from" "no notice file for $lib: expected $from"
  fi
}

# defined_symbols <archive> <anchor symbol or ""> <out file>: writes every external and private external
# definition of the archive (weak ones too), one name per line, sorted under LC_ALL=C. nm runs on its own, never in
# a pipe, so its failure stops the run; so do an empty list and a missing anchor, because "no symbol in common"
# proves nothing unless both lists are real.
defined_symbols() {
  local lib="$1" anchor="$2" out="$3"
  nm -m "$lib" >"$out.nm" 2>"$out.err" || stage_die 1 "nm failed on $lib: $(sed -n 1p "$out.err")"
  { grep -E ' (private )?external ' "$out.nm" || true; } | { grep -v '(undefined)' || true; } \
    | awk '{print $NF}' | LC_ALL=C sort -u >"$out"
  [ -s "$out" ] || stage_die 1 "nm lists no defined symbol in $lib, so it cannot show that compiler-rt is not linked"
  if [ -n "$anchor" ] && ! grep -qx -- "$anchor" "$out"; then
    stage_die 1 "$lib does not define $anchor, so it is not the library the $PDFIUM_NINJA_TARGET target builds"
  fi
}

# compiler_rt_not_linked <build dir> <archive paths as ninja lists them, one per line>: refuses when the library the
# pdfium target wrote (obj/libembedpdf.a with the EmbedPDF patches, else obj/libpdfium.a, as pdfium-build.sh picks
# it) defines any symbol that a listed compiler-rt archive defines.
compiler_rt_not_linked() {
  local build="$1" lib="" f rt both
  for f in "$build/obj/libembedpdf.a" "$build/obj/libpdfium.a"; do
    if [ -f "$f" ]; then
      lib="$f"
      break
    fi
  done
  [ -n "$lib" ] || stage_die 1 "ninja -t inputs $PDFIUM_NINJA_TARGET lists compiler-rt's builtins archive, but $build has no obj/libembedpdf.a or obj/libpdfium.a to show it is not linked: build the $PDFIUM_NINJA_TARGET target (scripts/pdfium-build.sh) before staging"
  command -v nm >/dev/null 2>&1 || stage_die 2 "required tool not found: nm"
  CRT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/licenses-compiler-rt.XXXXXX")"
  trap 'rm -rf "$CRT_TMP"' EXIT
  defined_symbols "$lib" _FPDF_InitLibrary "$CRT_TMP/lib"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rt="$build/$(printf '%s' "$f" | tr -d "'")"
    [ -f "$rt" ] || stage_die 1 "ninja -t inputs $PDFIUM_NINJA_TARGET lists the compiler-rt archive $f, but the clang package has no such file ($rt)"
    defined_symbols "$rt" "" "$CRT_TMP/rt"
    both="$(LC_ALL=C comm -12 "$CRT_TMP/lib" "$CRT_TMP/rt")"
    [ -z "$both" ] || stage_die 1 "compiler-rt is linked into $lib: it defines $(printf '%s\n' "$both" | wc -l | tr -d ' ') symbol(s) of $f (first: $(printf '%s\n' "$both" | sed -n 1p)), so the release would carry LLVM code (Apache-2.0 WITH LLVM-exception) without its notice: stage the LLVM compiler-rt license in stage_pdfium (scripts/licenses.sh) and require it in scripts/release-publish.sh"
    log "compiler-rt is not linked: $lib defines none of the $(wc -l <"$CRT_TMP/rt" | tr -d ' ') symbols of $f, so it needs no notice"
  done <<<"$2"
}

# third_party_refs <graph|built>: for every "third_party/<name>" on the lines read from stdin, prints
# <origin> US <name> US <line>, US being the unit separator (no path holds it). A name runs to the next '/';
# in build.ninja also to a space, ':', '|' or the '$' of an escaped ':' (ninja's separators). Nothing else is
# cut: 'libc++' stays 'libc++', a ninja escape inside a name stays in it, and an empty or odd name reaches
# the unknown-library check instead of vanishing.
third_party_refs() {
  local origin="$1" line rest name after
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [[ "$rest" == *third_party/* ]]; do
      rest="${rest#*third_party/}"
      if [ "$origin" = graph ]; then
        name="${rest%%[/ :\$|]*}"
        after="${rest:${#name}:2}"
        if [ "${after:0:1}" = '$' ] && [ "$after" != '$:' ]; then
          name="$name$after"
        fi
      else
        name="${rest%%/*}"
      fi
      printf '%s\037%s\037%s\n' "$origin" "$name" "$line"
    done
  done
}

stage_pdfium() { # <pdfium source dir> <ninja build dir> <stage dir>
  local src="$1" build="$2" out="$3/pdfium" ninja inputs refs built_names origin lib line where f clang_rts=""
  local us=$'\037' name_re='^[a-z0-9_-]+$'
  [ -d "$src" ] || die 2 "PDFium source directory not found: $src"
  [ -f "$build/build.ninja" ] || die 2 "build.ninja not found in $build"
  [ -f "$src/LICENSE" ] || die 1 "no notice file for pdfium: expected $src/LICENSE"
  # PDFium's DEPS pins ninja (third_party/ninja, 1.12.1 at chromium/8100), and the depot_tools wrapper
  # pdfium-build.sh calls runs that same binary. -t inputs needs ninja 1.11 or newer.
  ninja="${NINJA_BIN:-$src/third_party/ninja/ninja}"
  command -v "$ninja" >/dev/null 2>&1 \
    || die 2 "ninja not found: expected $ninja (gclient sync installs it from PDFium's DEPS), or set NINJA_BIN"
  rm -rf "$out"
  mkdir -p "$out"
  sed 's|^//[[:space:]]\{0,1\}||' "$src/LICENSE" >"$out/pdfium.txt"

  # Library names come from two places, and both meet the same list of cases below.
  # 1. build.ninja, GN's root file: an alias for every target and the outputs of "all". It names every library
  #    in the graph, header-only ones too (dragonbox and fast_float compile into PDFium's own objects and
  #    leave none of their own), and also tests and tools (IGNORED_THIRD_PARTY).
  # 2. ninja -t inputs pdfium: every file the pdfium target is built from, transitively. It sees code whose
  #    GN label is not under //third_party, such as //skia:redaction_pathops (EmbedPDF patch 0002), which
  #    compiles ../../third_party/skia/src/** into libpdfium.a while build.ninja only says "skia". Reading
  #    every obj/**/*.ninja instead would also take in every test and tool target of the graph, which no
  #    build log vouches for; the inputs of pdfium are exactly the steps the build runs. Only paths outside
  #    the build directory (../ or /, quoted when ninja escapes them) are sources; obj/, gen/ and phony/
  #    paths are outputs of other steps, whose own inputs are listed too.
  log "listing the inputs of $PDFIUM_NINJA_TARGET in $build with $ninja ($("$ninja" --version 2>/dev/null || echo 'version unknown'))"
  inputs="$("$ninja" -C "$build" -t inputs "$PDFIUM_NINJA_TARGET")" \
    || die 2 "ninja could not list the inputs of $PDFIUM_NINJA_TARGET in $build (it needs ninja 1.11 or newer and a build directory from gn gen)"
  refs="$(
    { grep 'third_party/' "$build/build.ninja" || true; } | third_party_refs graph
    printf '%s\n' "$inputs" | { grep -E "^'?(\.\./|/)" || true; } | { grep 'third_party/' || true; } | third_party_refs built
  )"

  # Every PDFium build compiles zlib and FreeType. Inputs without either are not the PDFium build's.
  built_names="$(printf '%s\n' "$refs" | { grep "^built$us" || true; } | cut -d "$us" -f 2 | sort -u)"
  for lib in zlib freetype; do
    grep -qx "$lib" <<<"$built_names" \
      || die 1 "ninja -t inputs $PDFIUM_NINJA_TARGET lists no source under third_party/$lib, which every PDFium build compiles: $build is not the build directory of PDFium's $PDFIUM_NINJA_TARGET target"
  done

  while IFS="$us" read -r origin lib line; do
    [ -n "$origin" ] || continue
    if [ "$origin" = graph ]; then
      where="build.ninja"
      case "$IGNORED_THIRD_PARTY" in *" $lib "*) continue ;; esac
    else
      where="ninja -t inputs $PDFIUM_NINJA_TARGET"
      case "$IGNORED_THIRD_PARTY" in
        *" $lib "*)
          note_problem "ignored $lib" "'$lib' is on IGNORED_THIRD_PARTY, but the $PDFIUM_NINJA_TARGET target compiles it ($where: ${line:0:200}), so it needs a notice: add a case to stage_pdfium in scripts/licenses.sh"
          continue
          ;;
      esac
    fi
    if ! [[ "$lib" =~ $name_re ]]; then
      unknown_library "$lib" "$where" "$line"
      continue
    fi
    case "$lib" in
      abseil | abseil-cpp) pdfium_notice "$lib" "$src/third_party/abseil-cpp/LICENSE" "$out/abseil.txt" ;;
      agg23 | fx_agg) cut_notice "$lib" "$src/third_party/agg23/agg_array.h" "$out/agg23.txt" '/^$/d;/#ifndef/,$d' ;;
      bigint) pdfium_notice "$lib" "$src/third_party/bigint/LICENSE" "$out/bigint.txt" ;;
      catapult) pdfium_notice "$lib" "$src/third_party/catapult/LICENSE" "$out/catapult.txt" ;;
      cpu_features) pdfium_notice "$lib" "$src/third_party/cpu_features/src/LICENSE" "$out/cpu_features.txt" ;;
      dragonbox)
        pdfium_notice "$lib" "$src/third_party/dragonbox/src/LICENSE-Apache2-LLVM" "$out/dragonbox-Apache2-LLVM.txt"
        pdfium_notice "$lib" "$src/third_party/dragonbox/src/LICENSE-Boost" "$out/dragonbox-Boost.txt"
        ;;
      fast_float) pdfium_notice "$lib" "$src/third_party/fast_float/src/LICENSE-MIT" "$out/fast_float.txt" ;;
      fp16) pdfium_notice "$lib" "$src/third_party/fp16/LICENSE" "$out/fp16.txt" ;;
      freetype | fx_freetype) pdfium_notice "$lib" "$src/third_party/freetype/FTL.TXT" "$out/freetype.txt" ;;
      harfbuzz) pdfium_notice "$lib" "$src/third_party/harfbuzz/src/COPYING" "$out/harfbuzz.txt" ;;
      highway) pdfium_notice "$lib" "$src/third_party/highway/LICENSE" "$out/highway.txt" ;;
      icu) pdfium_notice "$lib" "$src/third_party/icu/LICENSE" "$out/icu.txt" ;;
      lcms | lcms2 | fx_lcms | fx_lcms2) cut_notice "$lib" "$src/third_party/lcms/include/lcms2.h" "$out/lcms.txt" '/^$/,$d' ;;
      libpng | png) pdfium_notice "$lib" "$src/third_party/libpng/LICENSE" "$out/libpng.txt" ;;
      libjpeg_turbo | jpeg)
        pdfium_notice "$lib" "$src/third_party/libjpeg_turbo/LICENSE.md" "$out/libjpeg_turbo.md"
        pdfium_notice "$lib" "$src/third_party/libjpeg_turbo/README.ijg" "$out/libjpeg_turbo.ijg"
        ;;
      libopenjpeg | libopenjpeg2 | fx_libopenjpeg) cut_notice "$lib" "$src/third_party/libopenjpeg/openjpeg.c" "$out/libopenjpeg.txt" -n '1,/\*\//p' ;;
      libtiff | fx_tiff | tiff) cut_notice "$lib" "$src/third_party/libtiff/t4.h" "$out/libtiff.txt" '1d;s/^.\{0,3\}//;23,$d' ;;
      libunwind) pdfium_notice "$lib" "$src/third_party/libunwind/src/LICENSE.TXT" "$out/libunwind.txt" ;;
      # BSD-3-Clause. pdfium.gni sets pdf_use_libyuv = true; core/fxge and core/fxcodec link it.
      libyuv) pdfium_notice "$lib" "$src/third_party/libyuv/LICENSE" "$out/libyuv.txt" ;;
      # The clang package: only compiler-rt's builtins archive (CLANG_RT_RE), an input of the pdfium target that
      # is not linked into it. Every input path naming llvm-build is checked here (the loop sees one line per name):
      # the builtins archives go to compiler_rt_not_linked, which proves the "not linked" after the loop, and any
      # other file is unknown. No GN target lives under llvm-build, so build.ninja naming it is unknown.
      llvm-build)
        if [ "$origin" = graph ]; then
          unknown_library "$lib" "$where" "$line"
        else
          clang_rts="$(printf '%s\n' "$refs" | { grep "^built$us$lib$us" || true; } | cut -d "$us" -f 3- | { grep -E "$CLANG_RT_RE" || true; } | LC_ALL=C sort -u)"
          f="$(printf '%s\n' "$refs" | { grep "^built$us$lib$us" || true; } | cut -d "$us" -f 3- | { grep -Ev "$CLANG_RT_RE" || true; } | sed -n 1p)"
          [ -z "$f" ] || unknown_library "$lib" "$where" "$f"
        fi
        ;;
      llvm-libc) pdfium_notice "$lib" "$src/third_party/llvm-libc/src/LICENSE.TXT" "$out/llvm-libc.txt" ;;
      simdutf) pdfium_notice "$lib" "$src/third_party/simdutf/LICENSE" "$out/simdutf.txt" ;;
      # BSD-3-Clause. Seen through ninja -t inputs: //skia:redaction_pathops compiles Skia's path code.
      skia) pdfium_notice "$lib" "$src/third_party/skia/LICENSE" "$out/skia.txt" ;;
      zlib) cut_notice "$lib" "$src/third_party/zlib/zlib.h" "$out/zlib.txt" -n '/^\/\* zlib.h/,/\*\//p' ;;
      *) unknown_library "$lib" "$where" "$line" ;;
    esac
  done <<<"$(printf '%s\n' "$refs" | sort -t "$us" -k1,1 -k2,2 -u)"

  # The compiler-rt proof runs before the noted problems stop the run, so a linked archive shows in the same round;
  # its own failures go through stage_die and print the noted problems first.
  if [ -n "$clang_rts" ]; then
    compiler_rt_not_linked "$build" "$clang_rts"
  fi
  if [ -n "$PROBLEMS" ]; then
    stage_die 1 "stage-pdfium found $(printf '%s' "$PROBLEMS" | grep -c .) problem(s) in the PDFium notices, each listed above"
  fi

  # Skia objects in the build directory mean Skia code went into the library, whatever found it.
  if [ -d "$build/obj/skia" ] && [ ! -s "$out/skia.txt" ]; then
    die 1 "$build/obj/skia exists, so Skia code was compiled, but no Skia notice (skia.txt) was staged: ninja -t inputs $PDFIUM_NINJA_TARGET showed no third_party/skia source"
  fi
  for f in $REQUIRED_PDFIUM_NOTICES; do
    [ -s "$out/$f" ] || die 1 "the PDFium notice $f was not staged, but every PDFium build so far has linked that library: check that $build is the build directory of the $PDFIUM_NINJA_TARGET target, then review REQUIRED_PDFIUM_NOTICES in scripts/licenses.sh"
  done
  log "staged PDFium notices in $out ($(find "$out" -type f | wc -l | tr -d ' ') files): $(cd "$out" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
}

stage_qpdf() { # <stage dir>
  local out="$1" q="$WORK_DIR/src/qpdf-$QPDF_VERSION" j="$WORK_DIR/src/libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
  rm -rf "$out/qpdf" "$out/libjpeg-turbo"
  mkdir -p "$out/qpdf" "$out/libjpeg-turbo"
  copy_notice qpdf "$q/LICENSE.txt" "$out/qpdf/LICENSE.txt"
  copy_notice qpdf "$q/NOTICE.md" "$out/qpdf/NOTICE.md"
  copy_notice libjpeg-turbo "$j/LICENSE.md" "$out/libjpeg-turbo/LICENSE.md"
  copy_notice libjpeg-turbo "$j/README.ijg" "$out/libjpeg-turbo/README.ijg"
  log "staged qpdf $QPDF_VERSION and libjpeg-turbo $LIBJPEG_TURBO_VERSION notices in $out"
}

assemble() { # <stage dir>...
  local dir part f dest target="$DIST_DIR/LICENSES" embed=0
  [ "$#" -ge 1 ] || die 2 "usage: licenses.sh assemble <stage dir>..."
  rm -rf "$target" "$DIST_DIR/LICENSES.zip"
  mkdir -p "$target"

  for dir in "$@"; do
    [ -d "$dir" ] || die 1 "stage directory not found: $dir"
    for part in "$dir"/*/; do
      [ -d "$part" ] || continue
      mkdir -p "$target/$(basename "$part")"
      for f in "$part"*; do
        [ -f "$f" ] || continue
        dest="$target/$(basename "$part")/$(basename "$f")"
        if [ -f "$dest" ] && ! cmp -s "$f" "$dest"; then
          die 1 "two stage directories disagree about $(basename "$part")/$(basename "$f")"
        fi
        cp "$f" "$dest"
      done
    done
  done

  [ -d "$target/pdfium" ] || die 1 "no PDFium notices were staged (run stage-pdfium first)"
  [ -d "$target/qpdf" ] && [ -d "$target/libjpeg-turbo" ] || die 1 "no qpdf notices were staged (run stage-qpdf first)"

  # pdfium-binaries (MIT): the iOS and build patches adopted from it.
  [ -f "$REPO_ROOT/legal/pdfium-binaries/LICENSE" ] || die 1 "legal/pdfium-binaries/LICENSE is missing"
  mkdir -p "$target/pdfium-binaries"
  cp "$REPO_ROOT/legal/pdfium-binaries/LICENSE" "$target/pdfium-binaries/LICENSE"

  # EmbedPDF notices, only when the patch series is part of this build.
  if ls "$REPO_ROOT"/patches/embedpdf/*.patch >/dev/null 2>&1; then
    embed=1
    [ -f "$REPO_ROOT/legal/embedpdf/COMMIT" ] || die 1 "legal/embedpdf/COMMIT is missing"
    [ "$(tr -d '[:space:]' <"$REPO_ROOT/legal/embedpdf/COMMIT")" = "$EMBEDPDF_COMMIT" ] \
      || die 1 "legal/embedpdf was copied from a different commit than EMBEDPDF_COMMIT in versions.env; refresh it"
    mkdir -p "$target/embedpdf"
    copy_notice embedpdf "$REPO_ROOT/legal/embedpdf/LICENSE" "$target/embedpdf/LICENSE"
    copy_notice embedpdf "$REPO_ROOT/legal/embedpdf/NOTICE" "$target/embedpdf/NOTICE"
  fi

  # This repository's own scripts and patches.
  mkdir -p "$target/pdf-engine-builds"
  copy_notice pdf-engine-builds "$REPO_ROOT/LICENSE" "$target/pdf-engine-builds/LICENSE"
  copy_notice pdf-engine-builds "$REPO_ROOT/NOTICE" "$target/pdf-engine-builds/NOTICE"

  {
    echo "Third-party notices for the binaries in this release (${RELEASE_TAG:-unreleased build})"
    echo
    echo "PDFium.xcframework"
    echo "  PDFium, branch $PDFIUM_BRANCH: BSD-3-Clause style license plus the libraries in pdfium/"
    echo "  iOS and build patches adopted from bblanchon/pdfium-binaries (MIT): pdfium-binaries/"
    if [ "$embed" -eq 1 ]; then
      echo "  EmbedPDF runtime extensions at commit $EMBEDPDF_COMMIT (Apache-2.0 and BSD): embedpdf/"
    else
      echo "  Built without the EmbedPDF patch series."
    fi
    echo
    echo "QPDF.xcframework"
    echo "  qpdf $QPDF_VERSION (Apache-2.0), native crypto only: qpdf/"
    echo "  libjpeg-turbo $LIBJPEG_TURBO_VERSION (IJG and BSD): libjpeg-turbo/"
    echo "  zlib is the operating system's and is not bundled."
    echo
    echo "Build scripts and patches of this repository (Apache-2.0): pdf-engine-builds/"
  } >"$target/README.txt"

  require_cmd ditto
  (cd "$DIST_DIR" && ditto -c -k --keepParent LICENSES LICENSES.zip)
  log "wrote $DIST_DIR/LICENSES and LICENSES.zip ($(find "$target" -type f | wc -l | tr -d ' ') files)"
}

case "${1:-}" in
  stage-pdfium)
    [ "$#" -eq 4 ] || die 2 "usage: licenses.sh stage-pdfium <pdfium source dir> <ninja build dir> <stage dir>"
    stage_pdfium "$2" "$3" "$4"
    ;;
  stage-qpdf)
    [ "$#" -eq 2 ] || die 2 "usage: licenses.sh stage-qpdf <stage dir>"
    stage_qpdf "$2"
    ;;
  assemble)
    shift
    assemble "$@"
    ;;
  *) die 2 "usage: licenses.sh stage-pdfium|stage-qpdf|assemble ..." ;;
esac
