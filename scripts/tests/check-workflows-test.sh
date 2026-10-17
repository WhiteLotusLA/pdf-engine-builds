#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/check-workflows.sh: one clean set of workflows, then one planted violation at a time.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/check-workflows.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-workflows-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
SHA="3d3c42e5aac5ba805825da76410c181273ba90b1"

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# fresh <dir>: a clean pair of workflows
fresh() {
  rm -rf "$1"
  mkdir -p "$1"
  cat >"$1/lint.yml" <<EOF
name: lint
on: [push]
permissions:
  contents: read
jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@$SHA # v7.0.1
        with:
          persist-credentials: false
      - run: echo hello
EOF
  cat >"$1/release.yml" <<EOF
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/lint.yml
  release:
    runs-on: ubuntu-24.04
    needs: build
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@$SHA # v7.0.1
        with:
          persist-credentials: false
      - run: echo publish
EOF
}

# run <dir>: sets $out and $code
run() {
  set +e
  out="$("$SCRIPT" "$1" 2>&1)"
  code=$?
  set -e
}

# expect_fail <label> <dir> <text that must appear>
expect_fail() {
  run "$2"
  check "$1" $([ "$code" -eq 1 ] && grep -q -- "$3" <<<"$out"; echo $?)
}

fresh "$WORK/clean"
run "$WORK/clean"
check "a clean set of workflows passes" $([ "$code" -eq 0 ]; echo $?)

fresh "$WORK/d1"
sed -i.bak "s#actions/checkout@$SHA#actions/checkout@v4#" "$WORK/d1/lint.yml"
expect_fail "an action pinned to a tag is rejected" "$WORK/d1" "not pinned to a full commit SHA: actions/checkout@v4"

fresh "$WORK/d2"
sed -i.bak "s#actions/checkout@$SHA#actions/checkout@${SHA:0:39}#" "$WORK/d2/lint.yml"
expect_fail "a 39-character SHA is rejected" "$WORK/d2" "not pinned to a full commit SHA"

fresh "$WORK/d3"
sed -i.bak "s#- run: echo hello#- uses: docker://alpine:3.20#" "$WORK/d3/lint.yml"
expect_fail "a docker:// action is rejected" "$WORK/d3" "docker://alpine"

fresh "$WORK/d4"
sed -i.bak '/^permissions:/,/^  contents: read/d' "$WORK/d4/lint.yml"
expect_fail "a workflow with no top-level permissions is rejected" "$WORK/d4" "lint.yml: top-level permissions"

fresh "$WORK/d5"
sed -i.bak 's/^  contents: read/  contents: write/' "$WORK/d5/lint.yml"
expect_fail "top-level contents: write is rejected" "$WORK/d5" "lint.yml: top-level permissions"

fresh "$WORK/d6"
awk '{ print } /^    runs-on:/ { print "    permissions:"; print "      contents: write" }' "$WORK/d6/lint.yml" >"$WORK/d6/lint.new" && mv "$WORK/d6/lint.new" "$WORK/d6/lint.yml"
expect_fail "contents: write in a job other than release is rejected" "$WORK/d6" "only allowed in the release job of release.yml (found in job 'lint')"

fresh "$WORK/d7"
sed -i.bak 's/^  release:/  publish:/' "$WORK/d7/release.yml"
expect_fail "contents: write in a differently named job is rejected" "$WORK/d7" "found in job 'publish'"

fresh "$WORK/d8"
awk '{ print } /^      contents: write/ { print "      id-token: write" }' "$WORK/d8/release.yml" >"$WORK/d8/release.new" && mv "$WORK/d8/release.new" "$WORK/d8/release.yml"
expect_fail "an extra write scope such as id-token is rejected" "$WORK/d8" "write scope not allowed anywhere: id-token: write"

fresh "$WORK/d9"
sed -i.bak 's#runs-on: ubuntu-24.04#runs-on: macos-26-xlarge#' "$WORK/d9/lint.yml"
expect_fail "a larger runner is rejected" "$WORK/d9" "larger or self-hosted runners"

fresh "$WORK/d10"
sed -i.bak 's#runs-on: ubuntu-24.04#runs-on: self-hosted#' "$WORK/d10/lint.yml"
expect_fail "a self-hosted runner is rejected" "$WORK/d10" "larger or self-hosted runners"

fresh "$WORK/d11"
sed -i.bak '/persist-credentials: false/d; /^        with:$/d' "$WORK/d11/lint.yml"
expect_fail "checkout without persist-credentials: false is rejected" "$WORK/d11" "persist-credentials"

fresh "$WORK/d12"
awk '/^on:/ { print "on:"; print "  pull_request_target:"; next } { print }' "$WORK/d12/lint.yml" >"$WORK/d12/lint.new" && mv "$WORK/d12/lint.new" "$WORK/d12/lint.yml"
expect_fail "pull_request_target is rejected" "$WORK/d12" "pull_request_target"

fresh "$WORK/d14"
awk '{ print } /^    runs-on:/ { print "    permissions: { contents: write, id-token: write }" }' "$WORK/d14/lint.yml" >"$WORK/d14/lint.new" && mv "$WORK/d14/lint.new" "$WORK/d14/lint.yml"
expect_fail "write scopes in flow style are rejected" "$WORK/d14" "write scope not allowed anywhere"

fresh "$WORK/d15"
awk '{ print } /^    runs-on:/ { print "    permissions:"; print "      contents: \"write\"" }' "$WORK/d15/lint.yml" >"$WORK/d15/lint.new" && mv "$WORK/d15/lint.new" "$WORK/d15/lint.yml"
expect_fail "a quoted write scope in a job other than release is rejected" "$WORK/d15" "only allowed in the release job of release.yml (found in job 'lint')"

fresh "$WORK/d16"
sed -i.bak 's/^on: \[push\]/on: [push, pull_request_target]/' "$WORK/d16/lint.yml"
expect_fail "pull_request_target in a flow list is rejected" "$WORK/d16" "pull_request_target"

fresh "$WORK/d17"
sed -i.bak 's/^on: \[push\]/on: pull_request_target/' "$WORK/d17/lint.yml"
expect_fail "pull_request_target as a plain scalar is rejected" "$WORK/d17" "pull_request_target"

fresh "$WORK/d18"
sed -i.bak 's/^on: \[push\]/on: [push] # never pull_request_target/' "$WORK/d18/lint.yml"
run "$WORK/d18"
check "a comment that mentions pull_request_target is fine" $([ "$code" -eq 0 ]; echo $?)

fresh "$WORK/d13"
sed -i.bak "s|- uses: actions/checkout@$SHA # v7.0.1|- uses: ./.github/actions/local-thing|" "$WORK/d13/lint.yml"
sed -i.bak '/persist-credentials: false/d; /^        with:$/d' "$WORK/d13/lint.yml"
run "$WORK/d13"
check "a local ./ action needs no SHA" $([ "$code" -eq 0 ]; echo $?)

rm -rf "$WORK/empty"
mkdir "$WORK/empty"
expect_fail "an empty workflow directory is rejected" "$WORK/empty" "no workflow files"

run "$WORK/does-not-exist"
check "a missing directory is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "check-workflows-test: $failures failure(s)"; exit 1; fi
echo "check-workflows-test: all passed"
