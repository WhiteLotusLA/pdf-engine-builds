#!/usr/bin/env bash
# CI test (needs cmake, gh and network for the two source downloads; run it on the macOS runner,
# not on a laptop that is busy). It proves two things about the crypto choice:
#   1. With GnuTLS and OpenSSL made visible to pkg-config, the compiler and CMake (fake .pc files
#      and headers), the native-only configure still passes the config guard: the runner's
#      packages cannot leak in.
#   2. The poison is real: configuring the way upstream does by default (QB_ALLOW_IMPLICIT_CRYPTO=1)
#      under the same environment picks GnuTLS up, and the guard refuses it (exit 4).
# Only configure runs (QB_CONFIGURE_ONLY=1); libjpeg-turbo is built because qpdf's configure needs it.
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_SCRIPT="$PWD/scripts/qpdf-build.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-poison-ci.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

POISON="$TMP/poison"
mkdir -p "$POISON/lib/pkgconfig" "$POISON/include/gnutls" "$POISON/include/openssl"
printf '/* fake */\n' >"$POISON/include/gnutls/gnutls.h"
printf '/* fake */\n' >"$POISON/include/openssl/evp.h"
for pkg in gnutls openssl; do
  cat >"$POISON/lib/pkgconfig/$pkg.pc" <<PC
prefix=$POISON
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: $pkg
Description: fake $pkg planted by qpdf-poison-ci.sh
Version: 3.9.0
Libs: -L\${libdir} -l$pkg
Cflags: -I\${includedir}
PC
done

# Empty stand-in libraries, so the poison does not depend on pkg-config or on Homebrew's GnuTLS.
: >"$POISON/lib/libgnutls.dylib"
: >"$POISON/lib/libcrypto.dylib"

export PKG_CONFIG_PATH="$POISON/lib/pkgconfig"
export CPATH="$POISON/include"
export LIBRARY_PATH="$POISON/lib"
export CMAKE_PREFIX_PATH="$POISON"
export WORK_DIR="$TMP/work"
export OUT_DIR="$TMP/out"

set +e
out="$(QB_CONFIGURE_ONLY=1 "$BUILD_SCRIPT" macos-arm64 2>&1)"
code=$?
set -e
check "native-only configure passes the guard although GnuTLS and OpenSSL are visible" $([ "$code" -eq 0 ] && grep -q "qpdf-config-guard: ok" <<<"$out"; echo $?)

set +e
out="$(QB_ALLOW_IMPLICIT_CRYPTO=1 QB_CONFIGURE_ONLY=1 "$BUILD_SCRIPT" macos-arm64 2>&1)"
code=$?
set -e
check "the upstream default configure under the same environment is refused (exit 4)" $([ "$code" -eq 4 ]; echo $?)
check "the guard names GnuTLS as the reason" $(grep -q "GnuTLS crypto is enabled" <<<"$out"; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "qpdf-poison-ci: $failures failure(s)"
  exit 1
fi
echo "qpdf-poison-ci: all passed"
