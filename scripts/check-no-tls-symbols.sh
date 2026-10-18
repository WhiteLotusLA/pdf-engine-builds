#!/usr/bin/env bash
# Usage: scripts/check-no-tls-symbols.sh [--require-native] <archive.a>...
#
# Fails when a static archive contains a symbol that belongs to GnuTLS or OpenSSL. That would mean
# qpdf was built against a TLS library (LGPL for GnuTLS, a different license for OpenSSL) instead
# of its own native crypto. With --require-native it also fails unless qpdf's native crypto
# provider is present, so an archive with no crypto at all cannot pass.
#
# Exit codes: 0 clean, 1 forbidden symbol found or native provider missing, 2 usage or tool error.
set -euo pipefail

require_native=0
if [ "${1:-}" = "--require-native" ]; then
  require_native=1
  shift
fi
if [ "$#" -lt 1 ]; then
  echo "usage: check-no-tls-symbols.sh [--require-native] <archive.a>..." >&2
  exit 2
fi

# nm prints "U _gnutls_init" for a reference and "T _gnutls_init" for a definition. C++ names embed
# the class name, so the qpdf provider classes are matched too. EVP_ and RAND_bytes catch an
# OpenSSL build whose calls do not go through an OPENSSL_ named symbol.
forbidden='(gnutls_|OPENSSL_|QPDFCrypto_gnutls|QPDFCrypto_openssl|[ _]EVP_[A-Za-z]|[ _]RAND_bytes)'

status=0
for archive in "$@"; do
  if [ ! -f "$archive" ]; then
    echo "check-no-tls-symbols: not a file: $archive" >&2
    exit 2
  fi
  symbols="$(nm "$archive" 2>/dev/null)" || {
    echo "check-no-tls-symbols: nm failed on $archive" >&2
    exit 2
  }

  hits="$(grep -E "$forbidden" <<<"$symbols" | head -20 || true)"
  if [ -n "$hits" ]; then
    echo "check-no-tls-symbols: FORBIDDEN TLS symbols in $(basename "$archive"):" >&2
    printf '%s\n' "$hits" >&2
    status=1
  fi

  if [ "$require_native" -eq 1 ]; then
    if ! grep -q 'QPDFCrypto_native' <<<"$symbols"; then
      echo "check-no-tls-symbols: native crypto provider (QPDFCrypto_native) is missing from $(basename "$archive")" >&2
      status=1
    fi
  fi
done

if [ "$status" -eq 0 ]; then
  echo "check-no-tls-symbols: ok ($# archive(s) clean)"
fi
exit "$status"
