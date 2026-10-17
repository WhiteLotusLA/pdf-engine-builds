#!/usr/bin/env bash
# Usage: scripts/release-tag.sh <tag>
# Validates a release tag and prints what it means as KEY=VALUE lines (workflows append them to $GITHUB_OUTPUT):
#   version=0.0.1   pdfium=8086   stock=true|false   macos_only=true|false   prerelease=true|false
# Tag grammar: v<major>.<minor>.<patch>-pdfium<NNNN>[-stock][-macos-only]
#   -stock       built without the EmbedPDF patch series
#   -macos-only  only the macOS slice (no iOS slices, no QPDF)
# A tag with either suffix is a pre-release. The PDFium number in the tag must equal the PDFIUM_BRANCH pin in
# versions.env, so a tag can never name a different PDFium than the one that gets built.
# Exit codes: 0 ok, 2 the tag is malformed, 3 the tag does not match versions.env.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

[ "$#" -eq 1 ] || die 2 "usage: $SCRIPT_NAME <tag>"
TAG="$1"
re='^v([0-9]+\.[0-9]+\.[0-9]+)-pdfium([0-9]{4})(-stock)?(-macos-only)?$'
[[ "$TAG" =~ $re ]] || die 2 "tag '$TAG' does not match v<major>.<minor>.<patch>-pdfium<NNNN>[-stock][-macos-only]"

version="${BASH_REMATCH[1]}"
pdfium="${BASH_REMATCH[2]}"
stock=false
macos_only=false
[ -z "${BASH_REMATCH[3]}" ] || stock=true
[ -z "${BASH_REMATCH[4]}" ] || macos_only=true

require_env PDFIUM_BRANCH
if [ "$PDFIUM_BRANCH" != "chromium/$pdfium" ]; then
  die 3 "tag names PDFium $pdfium but versions.env pins $PDFIUM_BRANCH"
fi

prerelease=false
if [ "$stock" = true ] || [ "$macos_only" = true ]; then
  prerelease=true
fi
printf 'version=%s\npdfium=%s\nstock=%s\nmacos_only=%s\nprerelease=%s\n' "$version" "$pdfium" "$stock" "$macos_only" "$prerelease"
