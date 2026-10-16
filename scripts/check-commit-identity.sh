#!/usr/bin/env bash
# Usage: scripts/check-commit-identity.sh [revision-range]        (default: HEAD, the whole history)
# This repo is public, so every commit must carry the GitHub noreply address and never a personal one.
#   author e-mail:    must be the noreply address below
#   committer e-mail: the noreply address, or GitHub's own web-flow address (squash merges made on github.com)
# On a developer machine (CI unset) it also checks the repo-local git config.
# Offending e-mail addresses are never printed (CI logs of a public repo are public); only commit ids are.
# Exit codes: 0 ok, 1 a commit or the local config has the wrong identity, 2 not a git repository.
set -euo pipefail

NOREPLY="43762553+WhiteLotusLA@users.noreply.github.com"
WEBFLOW="noreply@github.com"
range="${1:-HEAD}"

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "check-commit-identity: not a git repository" >&2
  exit 2
}

bad=0
checked=0
while IFS='|' read -r sha author_email committer_email; do
  [ -n "$sha" ] || continue
  checked=$((checked + 1))
  if [ "$author_email" != "$NOREPLY" ]; then
    echo "FAIL: commit ${sha:0:12} has an author e-mail that is not the noreply address"
    bad=$((bad + 1))
  fi
  if [ "$committer_email" != "$NOREPLY" ] && [ "$committer_email" != "$WEBFLOW" ]; then
    echo "FAIL: commit ${sha:0:12} has a committer e-mail that is not the noreply address"
    bad=$((bad + 1))
  fi
done < <(git log --format='%H|%ae|%ce' "$range")

if [ -z "${CI:-}" ]; then
  if [ "$(git config --local user.email || true)" != "$NOREPLY" ]; then
    echo "FAIL: repo-local user.email is not the noreply address (run: git config user.email $NOREPLY)"
    bad=$((bad + 1))
  fi
fi

if [ "$bad" -gt 0 ]; then
  echo "check-commit-identity: $bad problem(s) in $checked commit(s)"
  exit 1
fi
echo "check-commit-identity: $checked commit(s) ok"
