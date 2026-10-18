#!/usr/bin/env bash
# Usage: scripts/pin-source-checksums.sh
#
# Records the SHA-256 of the qpdf and libjpeg-turbo source tarballs named by versions.env
# (QPDF_VERSION, LIBJPEG_TURBO_VERSION) in sources.sha256, trust-on-first-use with a cross-check:
# the hash GitHub computed when the release asset was uploaded (the asset's "digest" field) must
# equal the hash of the bytes actually downloaded. Run it whenever a version in versions.env
# changes, then review and commit the diff.
#
# Environment (optional): GH_BIN (default gh), SOURCES_SHA256_FILE (default <repo>/sources.sha256).
# Exit codes: 0 ok, 2 tool or version missing, 3 GitHub's digest and the download disagree or the
# asset has no digest.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions
require_env QPDF_VERSION LIBJPEG_TURBO_VERSION
GH="${GH_BIN:-gh}"
require_cmd "$GH" shasum
SOURCES_SHA256_FILE="${SOURCES_SHA256_FILE:-$REPO_ROOT/sources.sha256}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pin-sources.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pin() { # <github repo> <tag> <tarball name>
  local repo="$1" tag="$2" asset="$3" digest actual
  digest="$("$GH" api "repos/$repo/releases/tags/$tag" --jq ".assets[] | select(.name == \"$asset\") | .digest")"
  digest="${digest#sha256:}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die 3 "$repo $tag has no sha256 digest for $asset (got '${digest:0:20}')"
  mkdir -p "$TMP/$asset.dir"
  "$GH" release download "$tag" --repo "$repo" --pattern "$asset" --dir "$TMP/$asset.dir"
  actual="$(shasum -a 256 "$TMP/$asset.dir/$asset" | awk '{print $1}')"
  [ "$actual" = "$digest" ] || die 3 "$asset: GitHub's digest ${digest:0:12}... differs from the download ${actual:0:12}..."
  printf '%s  %s\n' "$digest" "$asset" >>"$TMP/new.sha256"
  log "$asset sha256 ${digest:0:12}... (GitHub digest and download agree)"
}

: >"$TMP/new.sha256"
pin qpdf/qpdf "v$QPDF_VERSION" "qpdf-$QPDF_VERSION.tar.gz"
pin libjpeg-turbo/libjpeg-turbo "$LIBJPEG_TURBO_VERSION" "libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz"
sort -k2 "$TMP/new.sha256" >"$SOURCES_SHA256_FILE"
log "wrote $SOURCES_SHA256_FILE"
