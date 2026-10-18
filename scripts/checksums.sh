#!/usr/bin/env bash
# Usage:
#   scripts/checksums.sh write  <dir> <asset-name>...   write <dir>/checksums.txt (SHA-256, one "hash  name" line per asset)
#   scripts/checksums.sh verify <dir>                   check every line of <dir>/checksums.txt against the files in <dir>
# The format is exactly what `shasum -a 256` prints in text mode, so consumers can run `shasum -a 256 -c checksums.txt`
# (the app repo's scripts/fetch-engines.sh compares each download with the SHA-256 pinned in its Engines.lock and
# does not read checksums.txt). verify refuses any line that is not 64 lowercase hex digits, two spaces and a plain
# file name (no slash): shasum -c picks the algorithm from each line's length and ignores -a 256, so a SHA-1 or
# SHA-512 line would otherwise verify; --strict makes shasum fail on a line it cannot read instead of skipping it.
# Exit codes: 0 ok, 1 verify found a mismatch, a missing file or a line that is not SHA-256, 2 usage error,
#             3 an asset to hash does not exist.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd shasum

cmd="${1:-}"
dir="${2:-}"
case "$cmd" in
  write)
    [ "$#" -ge 3 ] || die 2 "usage: $SCRIPT_NAME write <dir> <asset-name>..."
    [ -d "$dir" ] || die 2 "not a directory: $dir"
    shift 2
    for name in "$@"; do
      case "$name" in
        */* | .* | '') die 2 "asset names are plain file names, got '$name'" ;;
      esac
      [ -f "$dir/$name" ] || die 3 "asset not found: $dir/$name"
    done
    (cd "$dir" && shasum -a 256 "$@" >checksums.txt)
    log "wrote $dir/checksums.txt for $# asset(s)"
    ;;
  verify)
    [ "$#" -eq 2 ] || die 2 "usage: $SCRIPT_NAME verify <dir>"
    [ -f "$dir/checksums.txt" ] || die 1 "no checksums.txt in $dir"
    # grep -nv prints every line that is not a SHA-256 text-mode line as "<number>:<line>"; name the first by number
    # only. LC_ALL=C: the bracket ranges mean exactly the ASCII characters.
    if bad="$(LC_ALL=C grep -nvE '^[0-9a-f]{64}  [^/]+$' "$dir/checksums.txt")"; then
      die 1 "checksum verification failed in $dir: checksums.txt line ${bad%%:*} is not a SHA-256 line ('<64 lowercase hex>  <file name>')"
    fi
    if (cd "$dir" && shasum -a 256 --strict -c checksums.txt); then
      log "all checksums in $dir verify"
    else
      die 1 "checksum verification failed in $dir"
    fi
    ;;
  *) die 2 "usage: $SCRIPT_NAME write <dir> <asset-name>... | verify <dir>" ;;
esac
