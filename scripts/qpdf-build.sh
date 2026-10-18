#!/usr/bin/env bash
# Usage: scripts/qpdf-build.sh <slice>
#   slice: macos-arm64 | ios-arm64 | iossim-arm64
#
# Builds libjpeg-turbo (static), then qpdf (static, native crypto only) for one slice, and merges
# both into one archive.
# Result: out/qpdf/<slice>/libqpdf.a and out/qpdf/<slice>/Headers/qpdf/*.h and *.hh
#
# Inputs: versions.env (QPDF_VERSION, LIBJPEG_TURBO_VERSION, MACOS_MIN, IOS_MIN) and sources.sha256
# (the SHA-256 of each source tarball; scripts/pin-source-checksums.sh writes it).
#
# Environment (all optional):
#   WORK_DIR=<dir>               downloads, sources and build trees (default: <repo>/work)
#   OUT_DIR=<dir>                results (default: <repo>/out)
#   SOURCES_SHA256_FILE=<file>   (default: <repo>/sources.sha256)
#   QB_DRY_RUN=1                 print the commands instead of running them (no download, no build)
#   QB_FETCH_ONLY=1              download, verify and unpack the two source tarballs, then stop
#   QB_CONFIGURE_ONLY=1          stop after configuring qpdf and running the config guard
#   QB_ALLOW_IMPLICIT_CRYPTO=1   TESTS ONLY. Configure the way upstream does by default (implicit
#                                crypto providers, pkg-config not isolated) so tests can show the
#                                guard catches a runner that has GnuTLS or OpenSSL installed.
# Exit codes: 0 ok, 1 a cmake, gh, tar or libtool command failed (set -e passes its failure on),
#             2 usage or missing tool or pin, 3 checksum mismatch, 4 crypto guard failed,
#             5 build output missing or built for the wrong platform.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
SOURCES_SHA256_FILE="${SOURCES_SHA256_FILE:-$REPO_ROOT/sources.sha256}"
HERE="$COMMON_SH_DIR"
DRY="${QB_DRY_RUN:-0}"

run() { # prints the command in dry-run mode, runs it otherwise
  if [ "$DRY" = "1" ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

[ "$#" -eq 1 ] || die 2 "usage: qpdf-build.sh <macos-arm64|ios-arm64|iossim-arm64>"
SLICE="$1"
case "$SLICE" in
  macos-arm64)
    SDK_NAME=macosx
    SYSTEM_NAME=Darwin
    DEPLOY="${MACOS_MIN:-}"
    WANT_PLATFORM=MACOS
    ;;
  ios-arm64)
    SDK_NAME=iphoneos
    SYSTEM_NAME=iOS
    DEPLOY="${IOS_MIN:-}"
    WANT_PLATFORM=IOS
    ;;
  iossim-arm64)
    SDK_NAME=iphonesimulator
    SYSTEM_NAME=iOS
    DEPLOY="${IOS_MIN:-}"
    WANT_PLATFORM=IOSSIMULATOR
    ;;
  *) die 2 "unknown slice '$SLICE' (use macos-arm64, ios-arm64 or iossim-arm64)" ;;
esac

require_env QPDF_VERSION LIBJPEG_TURBO_VERSION
[ -n "$DEPLOY" ] || die 2 "versions.env does not define MACOS_MIN or IOS_MIN"
require_cmd xcrun
if [ "$DRY" != "1" ]; then
  require_cmd gh shasum tar
  if [ "${QB_FETCH_ONLY:-0}" != "1" ]; then require_cmd cmake; fi
fi

QPDF_TARBALL="qpdf-$QPDF_VERSION.tar.gz"
JPEG_TARBALL="libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz"

pinned_sha() { # <tarball name> -> the SHA-256 recorded in sources.sha256
  local sha=""
  if [ -f "$SOURCES_SHA256_FILE" ]; then
    sha="$(awk -v n="$1" '$2 == n { print $1 }' "$SOURCES_SHA256_FILE")"
  fi
  [ -n "$sha" ] || die 2 "no checksum for $1 in $SOURCES_SHA256_FILE; run scripts/pin-source-checksums.sh"
  printf '%s\n' "$sha"
}
QPDF_SHA256="$(pinned_sha "$QPDF_TARBALL")"
JPEG_SHA256="$(pinned_sha "$JPEG_TARBALL")"

SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
GENERATOR="Ninja"
command -v ninja >/dev/null 2>&1 || GENERATOR="Unix Makefiles"

QPDF_SRC="$WORK_DIR/src/qpdf-$QPDF_VERSION"
JPEG_SRC="$WORK_DIR/src/libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
BUILD="$WORK_DIR/build/$SLICE"
PREFIX="$BUILD/prefix"
OUT="$OUT_DIR/qpdf/$SLICE"

fetch_and_unpack() { # <github repo> <tag> <tarball name> <sha256> <destination dir>
  local repo="$1" tag="$2" asset="$3" want="$4" dest="$5"
  local archive="$WORK_DIR/downloads/$asset" got
  if [ -d "$dest" ]; then return 0; fi
  mkdir -p "$WORK_DIR/downloads"
  if [ ! -f "$archive" ]; then
    gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$WORK_DIR/downloads"
  fi
  got="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$archive"
    die 3 "checksum mismatch for $asset: sources.sha256 pins ${want:0:12}..., downloaded ${got:0:12}...; the download was deleted"
  fi
  rm -rf "$dest.partial"
  mkdir -p "$dest.partial"
  tar -xzf "$archive" -C "$dest.partial" --strip-components=1
  mv "$dest.partial" "$dest"
}

if [ "$DRY" != "1" ]; then
  fetch_and_unpack qpdf/qpdf "v$QPDF_VERSION" "$QPDF_TARBALL" "$QPDF_SHA256" "$QPDF_SRC"
  fetch_and_unpack libjpeg-turbo/libjpeg-turbo "$LIBJPEG_TURBO_VERSION" "$JPEG_TARBALL" "$JPEG_SHA256" "$JPEG_SRC"
  if [ "${QB_FETCH_ONLY:-0}" = "1" ]; then
    log "sources verified and unpacked in $WORK_DIR/src"
    exit 0
  fi
fi

# Flags shared by both CMake projects. The macOS slice is a native build; the iOS slices are
# cross builds. CMAKE_TRY_COMPILE_TARGET_TYPE keeps configure checks from linking executables,
# which would need code signing on iOS.
common=(
  -G "$GENERATOR"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_SYSROOT="$SDK_NAME"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY"
  -DCMAKE_C_COMPILER="$(xcrun --find clang)"
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)"
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)
system=()
if [ "$SYSTEM_NAME" = "iOS" ]; then
  system=(-DCMAKE_SYSTEM_NAME=iOS)
fi

# Crypto: native only. USE_IMPLICIT_CRYPTO=OFF stops qpdf's CMake from even looking for GnuTLS or
# OpenSSL; REQUIRE_CRYPTO_NATIVE=ON selects its own provider. The environment is also cleaned so
# nothing from the host (Homebrew prefixes, for example) leaks into an iOS build.
if [ "${QB_ALLOW_IMPLICIT_CRYPTO:-0}" = "1" ]; then
  crypto=(-DUSE_IMPLICIT_CRYPTO=ON)
else
  crypto=(-DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON -DREQUIRE_CRYPTO_OPENSSL=OFF -DREQUIRE_CRYPTO_GNUTLS=OFF)
  run mkdir -p "$BUILD/empty-pkgconfig"
  export PKG_CONFIG_LIBDIR="$BUILD/empty-pkgconfig"
  unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH \
    LIBRARY_PATH CMAKE_PREFIX_PATH CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH
fi

# --- libjpeg-turbo: static, no SIMD (qpdf only uses it for the optional DCT filter), no tools ---
run rm -rf "$BUILD/jpeg" "$BUILD/qpdf" "$PREFIX"
run mkdir -p "$PREFIX"
run cmake -S "$JPEG_SRC" -B "$BUILD/jpeg" "${common[@]}" ${system[@]+"${system[@]}"} \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DWITH_SIMD=0 -DWITH_TURBOJPEG=0 -DWITH_TOOLS=0 -DWITH_TESTS=0
run cmake --build "$BUILD/jpeg" --parallel
run cmake --install "$BUILD/jpeg"

# --- qpdf: static library only; zlib comes from the SDK; libjpeg-turbo from the step above ---
run cmake -S "$QPDF_SRC" -B "$BUILD/qpdf" "${common[@]}" ${system[@]+"${system[@]}"} "${crypto[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
  -DZLIB_H_PATH="$SDK_PATH/usr/include" -DZLIB_LIB_PATH="$SDK_PATH/usr/lib/libz.tbd" \
  -DLIBJPEG_H_PATH="$PREFIX/include" -DLIBJPEG_LIB_PATH="$PREFIX/lib/libjpeg.a" \
  -DENABLE_QTC=OFF -DREQUIRE_SHELLS=OFF -DWERROR=OFF -DGENERATE_AUTO_JOB=OFF -DBUILD_DOC=OFF \
  -DINSTALL_MANUAL=OFF -DINSTALL_EXAMPLES=OFF -DINSTALL_PKGCONFIG=OFF -DINSTALL_CMAKE_PACKAGE=OFF \
  -DCMAKE_SKIP_INSTALL_RULES=ON \
  -DCMAKE_PROJECT_INCLUDE="$HERE/cmake/no-macosx-bundle.cmake"

CONFIG_H="$BUILD/qpdf/libqpdf/qpdf/qpdf-config.h"
if [ "$DRY" = "1" ]; then
  echo "+ $HERE/qpdf-config-guard.sh $CONFIG_H"
else
  "$HERE/qpdf-config-guard.sh" "$CONFIG_H" || die 4 "the crypto guard refused this configuration (see above)"
fi

if [ "${QB_CONFIGURE_ONLY:-0}" = "1" ]; then
  log "configure only; stopping after the crypto guard"
  exit 0
fi

run cmake --build "$BUILD/qpdf" --target libqpdf --parallel

# --- merge qpdf and libjpeg-turbo, stage headers ---
LIB="$BUILD/qpdf/libqpdf/libqpdf.a"
if [ "$DRY" != "1" ] && [ ! -f "$LIB" ]; then
  die 5 "expected $LIB after the build and did not find it"
fi
run rm -rf "$OUT"
run mkdir -p "$OUT/Headers/qpdf"
run xcrun libtool -static -arch_only arm64 -o "$OUT/libqpdf.a" "$LIB" "$PREFIX/lib/libjpeg.a"
run sh -c 'cp "$1"/include/qpdf/*.h "$1"/include/qpdf/*.hh "$2"' _ "$QPDF_SRC" "$OUT/Headers/qpdf"

# --- checks on the result ---
check_platform() { # <archive> <platform name> <minimum OS version>
  local found
  found="$("$HERE/lib-platform.sh" "$1")" || die 5 "$(basename "$1") does not have a single build platform and minimum OS"
  if [ "$found" != "$2 $3" ]; then
    die 5 "$(basename "$1") has the wrong build platform: found '$found', wanted '$2 $3'"
  fi
}

if [ "$DRY" = "1" ]; then
  echo "+ check_platform $OUT/libqpdf.a $WANT_PLATFORM $DEPLOY"
  echo "+ $HERE/check-no-tls-symbols.sh --require-native $OUT/libqpdf.a"
  exit 0
fi

check_platform "$OUT/libqpdf.a" "$WANT_PLATFORM" "$DEPLOY"
"$HERE/check-no-tls-symbols.sh" --require-native "$OUT/libqpdf.a" || die 4 "TLS symbols found or native crypto missing in the built archive"
log "$SLICE ok ($(stat -f %z "$OUT/libqpdf.a") bytes, $WANT_PLATFORM minos $DEPLOY)"
