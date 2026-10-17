#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/check-commit-identity.sh using throwaway repositories.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/check-commit-identity.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-commit-identity-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
NOREPLY="43762553+WhiteLotusLA@users.noreply.github.com"
PERSONAL="someone.private@example.invalid"

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# commit_as <repo> <author email> <committer email> <message>
commit_as() {
  (
    cd "$1"
    echo "$4" >>file.txt
    git add file.txt
    GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL="$3" \
      git -c commit.gpgsign=false commit -q -m "$4"
  )
}

# run <repo> [args]: sets $out and $code. CI=1 skips the local-config check unless a test unsets it.
run() {
  local repo="$1"
  shift
  set +e
  out="$(cd "$repo" && "$SCRIPT" "$@" 2>&1)"
  code=$?
  set -e
}

new_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q -b main
}

export CI=1

new_repo "$WORK/good"
commit_as "$WORK/good" "$NOREPLY" "$NOREPLY" one
commit_as "$WORK/good" "$NOREPLY" "noreply@github.com" two
run "$WORK/good"
check "noreply author and committer, or GitHub web-flow committer, pass" $([ "$code" -eq 0 ] && grep -q "2 commit(s) ok" <<<"$out"; echo $?)

new_repo "$WORK/bad-author"
commit_as "$WORK/bad-author" "$NOREPLY" "$NOREPLY" one
commit_as "$WORK/bad-author" "$PERSONAL" "$NOREPLY" two
run "$WORK/bad-author"
check "a personal author e-mail fails" $([ "$code" -eq 1 ] && grep -q "author e-mail that is not the noreply address" <<<"$out"; echo $?)
check "the personal address is never printed" $(! grep -q "example.invalid" <<<"$out"; echo $?)

new_repo "$WORK/bad-committer"
commit_as "$WORK/bad-committer" "$NOREPLY" "$PERSONAL" one
run "$WORK/bad-committer"
check "a personal committer e-mail fails" $([ "$code" -eq 1 ] && grep -q "committer e-mail that is not the noreply address" <<<"$out"; echo $?)

new_repo "$WORK/range"
commit_as "$WORK/range" "$PERSONAL" "$PERSONAL" old
base="$(git -C "$WORK/range" rev-parse HEAD)"
commit_as "$WORK/range" "$NOREPLY" "$NOREPLY" new
run "$WORK/range" "$base..HEAD"
check "a revision range checks only the new commits" $([ "$code" -eq 0 ] && grep -q "1 commit(s) ok" <<<"$out"; echo $?)

run "$WORK/good" does-not-exist..HEAD
check "a bad revision range exits 2 and never reports success" $([ "$code" -eq 2 ] && ! grep -q "commit(s) ok" <<<"$out"; echo $?)

# Local config check (only outside CI)
git -C "$WORK/good" config user.email "$PERSONAL"
set +e
out="$(cd "$WORK/good" && env -u CI "$SCRIPT" 2>&1)"
code=$?
set -e
check "outside CI a wrong repo-local user.email fails" $([ "$code" -eq 1 ] && grep -q "repo-local user.email" <<<"$out"; echo $?)
git -C "$WORK/good" config user.email "$NOREPLY"
set +e
out="$(cd "$WORK/good" && env -u CI "$SCRIPT" 2>&1)"
code=$?
set -e
check "outside CI the right repo-local user.email passes" $([ "$code" -eq 0 ]; echo $?)

mkdir "$WORK/plain"
set +e
out="$(cd "$WORK/plain" && GIT_CEILING_DIRECTORIES="$WORK" "$SCRIPT" 2>&1)"
code=$?
set -e
check "outside a git repository exits 2" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "check-commit-identity-test: $failures failure(s)"; exit 1; fi
echo "check-commit-identity-test: all passed"
