#!/usr/bin/env bash
# Usage: scripts/qpdf-config-guard.sh <path/to/qpdf-config.h>
#
# Reads the qpdf-config.h that qpdf's CMake configure step generated and fails unless the build
# is native-crypto only. This runs right after configure, before any compile, so a runner that
# happens to have GnuTLS or OpenSSL installed cannot slip one in.
#
# Exit codes: 0 native only, 1 any other crypto setup, 2 usage.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: qpdf-config-guard.sh <path/to/qpdf-config.h>" >&2
  exit 2
fi
config="$1"

bad=0
complain() {
  echo "qpdf-config-guard: $1" >&2
  bad=1
}

grep -Eq '^#define USE_CRYPTO_NATIVE 1$' "$config" || complain "native crypto is not enabled"
if grep -Eq '^#define USE_CRYPTO_GNUTLS ' "$config"; then complain "GnuTLS crypto is enabled"; fi
if grep -Eq '^#define USE_CRYPTO_OPENSSL ' "$config"; then complain "OpenSSL crypto is enabled"; fi
grep -Eq '^#define DEFAULT_CRYPTO "native"$' "$config" || complain "the default crypto provider is not native"

if [ "$bad" -ne 0 ]; then
  echo "qpdf-config-guard: refusing to build; qpdf must use native crypto only (see $config)" >&2
  exit 1
fi
echo "qpdf-config-guard: ok (native crypto only)"
