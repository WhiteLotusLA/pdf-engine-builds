#!/usr/bin/env bash
# Usage:
#   scripts/checksums.sh write  <dir> <asset-name>...   write <dir>/checksums.txt (SHA-256, one "hash  name" line per asset)
#   scripts/checksums.sh verify <dir>                   check every line of <dir>/checksums.txt against the files in <dir>
# The format is exactly what `shasum -a 256` prints, so consumers can run `shasum -a 256 -c checksums.txt`
# (the app repo's scripts/fetch-engines.sh reads the first column for the asset it wants).
# Exit codes: 0 ok, 1 verify found a mismatch or a missing file, 2 usage error, 3 an asset to hash does not exist.
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
    if (cd "$dir" && shasum -a 256 -c checksums.txt); then
      log "all checksums in $dir verify"
    else
      die 1 "checksum verification failed in $dir"
    fi
    ;;
  *) die 2 "usage: $SCRIPT_NAME write <dir> <asset-name>... | verify <dir>" ;;
esac
