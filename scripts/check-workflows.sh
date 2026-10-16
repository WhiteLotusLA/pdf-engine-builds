#!/usr/bin/env bash
# Usage: scripts/check-workflows.sh [workflow-dir]        (default: .github/workflows)
# Enforces the build repo's workflow policy with plain text checks, so it runs on any machine:
#   1. every third-party action is pinned to a full 40-character commit SHA (local ./ calls are fine)
#   2. every workflow has a top-level "permissions:" block that is exactly "contents: read"
#   3. "contents: write" appears only in a job named "release" of release.yml; no other write scope anywhere
#   4. no larger runners and no self-hosted runners
#   5. every actions/checkout step sets "persist-credentials: false"
#   6. no pull_request_target trigger
# Exit codes: 0 clean, 1 violations (each printed as a FAIL line), 2 usage error.
set -euo pipefail

DIR="${1:-.github/workflows}"
if [ ! -d "$DIR" ]; then
  echo "check-workflows: no such directory: $DIR" >&2
  exit 2
fi

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

shopt -s nullglob
files=("$DIR"/*.yml "$DIR"/*.yaml)
if [ "${#files[@]}" -eq 0 ]; then
  fail "no workflow files in $DIR"
fi

sha_re='^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$'

# ${files[@]+...}: bash 3.2 (macOS /bin/bash) treats "${files[@]}" of an empty array as unbound under set -u.
for f in ${files[@]+"${files[@]}"}; do
  name="$(basename "$f")"

  # 1. pinned actions
  while IFS= read -r line; do
    ref="$(sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' <<<"$line")"
    case "$ref" in ./*) continue ;; esac
    if ! [[ "$ref" =~ $sha_re ]]; then
      fail "$name: action is not pinned to a full commit SHA: $ref"
    fi
  done < <(grep -E '^[[:space:]-]*uses:' "$f" || true)

  # 2. top-level permissions block
  block="$(awk '
    /^permissions:/ { inblock = 1; next }
    inblock && /^[[:space:]]*#/ { next }
    inblock && /^[[:space:]]*$/ { next }
    inblock && /^[[:space:]]+[^[:space:]]/ { gsub(/^[ \t]+|[ \t]+$/, ""); print; next }
    inblock { exit }
  ' "$f")"
  if [ "$block" != "contents: read" ]; then
    fail "$name: top-level permissions must be exactly 'contents: read'"
  fi

  # 3. write scopes
  while IFS= read -r hit; do
    job="${hit%%|*}"
    scope="${hit#*|}"
    if [ "$scope" != "contents: write" ]; then
      fail "$name: write scope not allowed anywhere: $scope"
    elif [ "$name" != "release.yml" ] || [ "$job" != "release" ]; then
      fail "$name: 'contents: write' is only allowed in the release job of release.yml (found in job '$job')"
    fi
  done < <(awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job) }
    /^[[:space:]]+[a-z-]+:[[:space:]]*write(-all)?[[:space:]]*(#.*)?$/ { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); sub(/[ \t]*#.*$/, "", line); print job "|" line }
    /^permissions:[[:space:]]*write-all/ { print "-|write-all" }
  ' "$f")

  # 4. runners
  if grep -E '^[[:space:]]*runs-on:.*(large|self-hosted)' "$f" >/dev/null; then
    fail "$name: larger or self-hosted runners are not allowed (standard GitHub-hosted runners only)"
  fi

  # 5. checkout without persisted credentials
  checkouts="$(grep -cE 'uses:[[:space:]]*actions/checkout@' "$f" || true)"
  persists="$(grep -cE '^[[:space:]]*persist-credentials:[[:space:]]*false' "$f" || true)"
  if [ "$checkouts" -ne "$persists" ]; then
    fail "$name: every actions/checkout needs 'persist-credentials: false' ($checkouts checkout, $persists persist-credentials)"
  fi

  # 6. dangerous trigger
  if grep -E '^[[:space:]]*pull_request_target' "$f" >/dev/null; then
    fail "$name: pull_request_target is not allowed"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "check-workflows: $failures violation(s)"
  exit 1
fi
echo "check-workflows: ${#files[@]} workflow file(s) clean"
