#!/usr/bin/env bash
# Usage:
#   scripts/licenses.sh stage-pdfium <pdfium source dir> <ninja build dir> <stage dir>
#       Copies the notice of PDFium and of every third_party library that the GN graph names
#       (build.ninja) or that the pdfium target compiles (ninja -t inputs pdfium) into
#       <stage dir>/pdfium/. A library this script does not know fails the run, so a new upstream
#       dependency is reviewed before it ships; so do compiled Skia objects without a Skia notice
#       and a missing notice of a library every PDFium build links (REQUIRED_PDFIUM_NOTICES).
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

copy_notice() { # <library> <source file> <destination file>
  [ -f "$2" ] || die 1 "no notice file for $1: expected $2"
  cp "$2" "$3"
}

unknown_library() { # <name> <where it was found> <the line> <pdfium source dir>
  die 1 "unknown third_party library '$1' in the PDFium build ($2: ${3:0:200}): read $4/third_party/$1, then add a case to stage_pdfium (or, for a test or build tool that the $PDFIUM_NINJA_TARGET target does not compile, to IGNORED_THIRD_PARTY) in scripts/licenses.sh"
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
  local src="$1" build="$2" out="$3/pdfium" ninja inputs refs built_names origin lib line where f
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
        *" $lib "*) die 1 "'$lib' is on IGNORED_THIRD_PARTY, but the $PDFIUM_NINJA_TARGET target compiles it ($where: ${line:0:200}), so it needs a notice: add a case to stage_pdfium in scripts/licenses.sh" ;;
      esac
    fi
    [[ "$lib" =~ $name_re ]] || unknown_library "$lib" "$where" "$line" "$src"
    case "$lib" in
      abseil | abseil-cpp) copy_notice "$lib" "$src/third_party/abseil-cpp/LICENSE" "$out/abseil.txt" ;;
      agg23 | fx_agg)
        [ -f "$src/third_party/agg23/agg_array.h" ] || die 1 "no notice file for $lib: expected $src/third_party/agg23/agg_array.h"
        sed '/^$/d;/#ifndef/,$d' "$src/third_party/agg23/agg_array.h" >"$out/agg23.txt"
        ;;
      bigint) copy_notice "$lib" "$src/third_party/bigint/LICENSE" "$out/bigint.txt" ;;
      catapult) copy_notice "$lib" "$src/third_party/catapult/LICENSE" "$out/catapult.txt" ;;
      cpu_features) copy_notice "$lib" "$src/third_party/cpu_features/src/LICENSE" "$out/cpu_features.txt" ;;
      dragonbox)
        copy_notice "$lib" "$src/third_party/dragonbox/src/LICENSE-Apache2-LLVM" "$out/dragonbox-Apache2-LLVM.txt"
        copy_notice "$lib" "$src/third_party/dragonbox/src/LICENSE-Boost" "$out/dragonbox-Boost.txt"
        ;;
      fast_float) copy_notice "$lib" "$src/third_party/fast_float/src/LICENSE-MIT" "$out/fast_float.txt" ;;
      fp16) copy_notice "$lib" "$src/third_party/fp16/LICENSE" "$out/fp16.txt" ;;
      freetype | fx_freetype) copy_notice "$lib" "$src/third_party/freetype/FTL.TXT" "$out/freetype.txt" ;;
      harfbuzz) copy_notice "$lib" "$src/third_party/harfbuzz/src/COPYING" "$out/harfbuzz.txt" ;;
      highway) copy_notice "$lib" "$src/third_party/highway/LICENSE" "$out/highway.txt" ;;
      icu) copy_notice "$lib" "$src/third_party/icu/LICENSE" "$out/icu.txt" ;;
      lcms | lcms2 | fx_lcms | fx_lcms2)
        [ -f "$src/third_party/lcms/include/lcms2.h" ] || die 1 "no notice file for $lib: expected $src/third_party/lcms/include/lcms2.h"
        sed '/^$/,$d' "$src/third_party/lcms/include/lcms2.h" >"$out/lcms.txt"
        ;;
      libpng | png) copy_notice "$lib" "$src/third_party/libpng/LICENSE" "$out/libpng.txt" ;;
      libjpeg_turbo | jpeg)
        copy_notice "$lib" "$src/third_party/libjpeg_turbo/LICENSE.md" "$out/libjpeg_turbo.md"
        copy_notice "$lib" "$src/third_party/libjpeg_turbo/README.ijg" "$out/libjpeg_turbo.ijg"
        ;;
      libopenjpeg | libopenjpeg2 | fx_libopenjpeg)
        [ -f "$src/third_party/libopenjpeg/openjpeg.c" ] || die 1 "no notice file for $lib: expected $src/third_party/libopenjpeg/openjpeg.c"
        sed -n '1,/\*\//p' "$src/third_party/libopenjpeg/openjpeg.c" >"$out/libopenjpeg.txt"
        ;;
      libtiff | fx_tiff | tiff)
        [ -f "$src/third_party/libtiff/t4.h" ] || die 1 "no notice file for $lib: expected $src/third_party/libtiff/t4.h"
        sed '1d;s/^.\{0,3\}//;23,$d' "$src/third_party/libtiff/t4.h" >"$out/libtiff.txt"
        ;;
      libunwind) copy_notice "$lib" "$src/third_party/libunwind/src/LICENSE.TXT" "$out/libunwind.txt" ;;
      # BSD-3-Clause. pdfium.gni sets pdf_use_libyuv = true; core/fxge and core/fxcodec link it.
      libyuv) copy_notice "$lib" "$src/third_party/libyuv/LICENSE" "$out/libyuv.txt" ;;
      llvm-libc) copy_notice "$lib" "$src/third_party/llvm-libc/src/LICENSE.TXT" "$out/llvm-libc.txt" ;;
      simdutf) copy_notice "$lib" "$src/third_party/simdutf/LICENSE" "$out/simdutf.txt" ;;
      # BSD-3-Clause. Seen through ninja -t inputs: //skia:redaction_pathops compiles Skia's path code.
      skia) copy_notice "$lib" "$src/third_party/skia/LICENSE" "$out/skia.txt" ;;
      zlib)
        [ -f "$src/third_party/zlib/zlib.h" ] || die 1 "no notice file for $lib: expected $src/third_party/zlib/zlib.h"
        sed -n '/^\/\* zlib.h/,/\*\//p' "$src/third_party/zlib/zlib.h" >"$out/zlib.txt"
        ;;
      *) unknown_library "$lib" "$where" "$line" "$src" ;;
    esac
  done <<<"$(printf '%s\n' "$refs" | sort -t "$us" -k1,1 -k2,2 -u)"

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
