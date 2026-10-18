#!/usr/bin/env bash
# Usage:
#   scripts/licenses.sh stage-pdfium <pdfium source dir> <ninja build dir> <stage dir>
#       Copies the notice of PDFium and of every third_party library that the build graph
#       (build.ninja) actually references into <stage dir>/pdfium/. A library this script does
#       not know fails the run, so a new upstream dependency is reviewed before it ships.
#   scripts/licenses.sh stage-qpdf <stage dir>
#       Copies the qpdf and libjpeg-turbo notices from the unpacked sources in $WORK_DIR/src
#       into <stage dir>/qpdf/ and <stage dir>/libjpeg-turbo/.
#   scripts/licenses.sh assemble <stage dir>...
#       Merges the stage dirs, adds the committed notices in legal/ and this repo's own LICENSE
#       and NOTICE, writes dist/LICENSES/ with a README.txt, and zips it to dist/LICENSES.zip.
#
# Environment (optional): WORK_DIR, DIST_DIR, RELEASE_TAG (shown in README.txt).
# Exit codes: 0 ok, 1 a notice is missing, unknown or stale, 2 usage or tool missing.
set -euo pipefail

# Notice files may hold bytes that are not valid UTF-8 (names in Latin-1); sed in a UTF-8 locale
# stops at the first one. Read everything as bytes.
export LC_ALL=C

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

# Libraries that appear in build.ninja but are never linked into libpdfium.a (tests, build tools).
IGNORED_THIRD_PARTY=" nasm googletest test_fonts libc vinn "

copy_notice() { # <library> <source file> <destination file>
  [ -f "$2" ] || die 1 "no notice file for $1: expected $2"
  cp "$2" "$3"
}

stage_pdfium() { # <pdfium source dir> <ninja build dir> <stage dir>
  local src="$1" build="$2" out="$3/pdfium" lib libs
  [ -d "$src" ] || die 2 "PDFium source directory not found: $src"
  [ -f "$build/build.ninja" ] || die 2 "build.ninja not found in $build"
  [ -f "$src/LICENSE" ] || die 1 "no notice file for pdfium: expected $src/LICENSE"
  rm -rf "$out"
  mkdir -p "$out"
  sed 's|^//[[:space:]]\{0,1\}||' "$src/LICENSE" >"$out/pdfium.txt"

  libs="$(sed -n 's/.*third_party\/\([a-z0-9_-]*\).*/\1/p' "$build/build.ninja" | sort -u)"
  while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    case "$IGNORED_THIRD_PARTY" in *" $lib "*) continue ;; esac
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
      llvm-libc) copy_notice "$lib" "$src/third_party/llvm-libc/src/LICENSE.TXT" "$out/llvm-libc.txt" ;;
      simdutf) copy_notice "$lib" "$src/third_party/simdutf/LICENSE" "$out/simdutf.txt" ;;
      zlib)
        [ -f "$src/third_party/zlib/zlib.h" ] || die 1 "no notice file for $lib: expected $src/third_party/zlib/zlib.h"
        sed -n '/^\/\* zlib.h/,/\*\//p' "$src/third_party/zlib/zlib.h" >"$out/zlib.txt"
        ;;
      *) die 1 "unknown third_party library '$lib' in the PDFium build graph: read $src/third_party/$lib, then add a case to stage_pdfium (or to IGNORED_THIRD_PARTY if it is a test or build tool) in scripts/licenses.sh" ;;
    esac
  done <<<"$libs"
  log "staged PDFium notices in $out ($(ls -1 "$out" | wc -l | tr -d ' ') files)"
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
