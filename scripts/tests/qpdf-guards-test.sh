#!/usr/bin/env bash
# Self-test for the two qpdf crypto guards:
#   scripts/check-no-tls-symbols.sh   (nm scan of a static archive)
#   scripts/qpdf-config-guard.sh      (reads the generated qpdf-config.h)
# Builds tiny archives with clang and ar (needs Xcode command line tools; no cmake, no network).
# Covers: a clean archive passes; a GnuTLS reference, an OpenSSL reference and a qpdf OpenSSL
# provider class each fail; --require-native fails without the native provider and passes with it;
# the config guard passes native-only and fails GnuTLS, OpenSSL, mixed and missing-native headers.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "qpdf-guards-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
NMCHECK="$PWD/scripts/check-no-tls-symbols.sh"
CFGGUARD="$PWD/scripts/qpdf-config-guard.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-guards-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# expect_exit <label> <expected code> <command...>: runs the command, records output in $out
out=""
expect_exit() {
  local label="$1" want="$2" got=0
  shift 2
  out="$("$@" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then echo "ok:   $label"; else echo "FAIL: $label (exit $got, wanted $want)"; failures=$((failures + 1)); fi
}

# --- tiny archives -------------------------------------------------------------------------
mkarchive() { # <name> <C source>
  printf '%s\n' "$2" >"$WORK/$1.c"
  xcrun clang -c -O0 -arch arm64 "$WORK/$1.c" -o "$WORK/$1.o"
  rm -f "$WORK/$1.a"
  ar rcs "$WORK/$1.a" "$WORK/$1.o" 2>/dev/null
}
mkarchive clean   'int qb_clean(void) { return 0; }'
mkarchive native  'int QPDFCrypto_native_stub(void) { return 0; }'
mkarchive gnutls  'extern int gnutls_cipher_init(void); int qb_use(void) { return gnutls_cipher_init(); }'
mkarchive openssl 'extern int OPENSSL_init_crypto(void); int qb_use(void) { return OPENSSL_init_crypto(); }'
mkarchive evp     'extern int EVP_MD_CTX_new(void); int qb_use(void) { return EVP_MD_CTX_new(); }'
mkarchive gnutlsclass 'int QPDFCrypto_gnutls_stub(void) { return 0; }'

# --- check-no-tls-symbols.sh ---------------------------------------------------------------
expect_exit "clean archive passes" 0 "$NMCHECK" "$WORK/clean.a"
expect_exit "a GnuTLS reference fails" 1 "$NMCHECK" "$WORK/gnutls.a"
check "the failure names the symbol" $(grep -q "gnutls_cipher_init" <<<"$out"; echo $?)
expect_exit "an OpenSSL OPENSSL_ reference fails" 1 "$NMCHECK" "$WORK/openssl.a"
expect_exit "an OpenSSL EVP_ reference fails" 1 "$NMCHECK" "$WORK/evp.a"
expect_exit "the qpdf GnuTLS provider class fails" 1 "$NMCHECK" "$WORK/gnutlsclass.a"
expect_exit "one bad archive among clean ones fails" 1 "$NMCHECK" "$WORK/clean.a" "$WORK/gnutls.a" "$WORK/native.a"
expect_exit "--require-native passes when the native provider is present" 0 "$NMCHECK" --require-native "$WORK/native.a"
expect_exit "--require-native fails when no crypto provider is present" 1 "$NMCHECK" --require-native "$WORK/clean.a"
expect_exit "a missing file is a usage error" 2 "$NMCHECK" "$WORK/does-not-exist.a"
expect_exit "no arguments is a usage error" 2 "$NMCHECK"

# --- qpdf-config-guard.sh ------------------------------------------------------------------
cfg() { # <name> <lines...>
  local name="$1"
  shift
  printf '%s\n' "$@" >"$WORK/$name.h"
}
cfg native      '#define DEFAULT_CRYPTO "native"' '#define USE_CRYPTO_NATIVE 1' '/* #undef USE_CRYPTO_GNUTLS */' '/* #undef USE_CRYPTO_OPENSSL */'
cfg gnutls      '#define DEFAULT_CRYPTO "gnutls"' '#define USE_CRYPTO_GNUTLS 1' '#define USE_CRYPTO_NATIVE 1'
cfg openssl     '#define DEFAULT_CRYPTO "openssl"' '#define USE_CRYPTO_OPENSSL 1'
cfg mixed       '#define DEFAULT_CRYPTO "native"' '#define USE_CRYPTO_NATIVE 1' '#define USE_CRYPTO_OPENSSL 1'
cfg nonative    '#define DEFAULT_CRYPTO "native"' '/* #undef USE_CRYPTO_NATIVE */'
cfg wrongdefault '#define DEFAULT_CRYPTO "gnutls"' '#define USE_CRYPTO_NATIVE 1'
expect_exit "native-only config passes" 0 "$CFGGUARD" "$WORK/native.h"
expect_exit "a GnuTLS config fails" 1 "$CFGGUARD" "$WORK/gnutls.h"
check "the config failure says GnuTLS" $(grep -q "GnuTLS crypto is enabled" <<<"$out"; echo $?)
expect_exit "an OpenSSL config fails" 1 "$CFGGUARD" "$WORK/openssl.h"
expect_exit "native plus OpenSSL fails" 1 "$CFGGUARD" "$WORK/mixed.h"
expect_exit "a config without native crypto fails" 1 "$CFGGUARD" "$WORK/nonative.h"
expect_exit "a config whose default is not native fails" 1 "$CFGGUARD" "$WORK/wrongdefault.h"
expect_exit "a missing header is a usage error" 2 "$CFGGUARD" "$WORK/missing.h"

if [ "$failures" -gt 0 ]; then
  echo "qpdf-guards-test: $failures failure(s)"
  exit 1
fi
echo "qpdf-guards-test: all passed"
