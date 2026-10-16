#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/common.sh: die, require_env, require_cmd, is_hex40 and load_versions.
set -euo pipefail
cd "$(dirname "$0")/../.."
COMMON="$PWD/scripts/common.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/common-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# run_clean <bash snippet>: run the snippet with common.sh sourced and a clean environment.
run_clean() {
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" TMPDIR="$WORK" COMMON="$COMMON" "${@:2}" bash -c ". \"\$COMMON\"; $1" 2>&1)"
  code=$?
  set -e
}

# die
run_clean 'die 7 "boom"'
check "die exits with the given code" $([ "$code" -eq 7 ]; echo $?)
check "die prints 'error: boom' on stderr" $(grep -q "error: boom" <<<"$out"; echo $?)

# require_env
run_clean 'require_env SOME_UNSET_A SOME_UNSET_B'
check "require_env exits 2 when variables are missing" $([ "$code" -eq 2 ]; echo $?)
check "require_env names every missing variable" $(grep -q "SOME_UNSET_A" <<<"$out" && grep -q "SOME_UNSET_B" <<<"$out"; echo $?)
run_clean 'require_env SOME_SET_A SOME_SET_B; echo fine' SOME_SET_A=1 SOME_SET_B=2
check "require_env passes when variables are set" $([ "$code" -eq 0 ] && grep -q fine <<<"$out"; echo $?)
run_clean 'require_env SOME_EMPTY' SOME_EMPTY=
check "require_env treats an empty variable as missing" $([ "$code" -eq 2 ]; echo $?)

# require_cmd
run_clean 'require_cmd bash'
check "require_cmd passes for a tool that exists" $([ "$code" -eq 0 ]; echo $?)
run_clean 'require_cmd definitely-not-a-real-tool-xyz'
check "require_cmd exits 2 for a missing tool" $([ "$code" -eq 2 ] && grep -q "definitely-not-a-real-tool-xyz" <<<"$out"; echo $?)

# is_hex40
GOOD40="0123456789abcdef0123456789abcdef01234567"
run_clean "is_hex40 $GOOD40 && echo yes"
check "is_hex40 accepts 40 lowercase hex characters" $(grep -q yes <<<"$out"; echo $?)
run_clean "is_hex40 ${GOOD40}0 || echo no"
check "is_hex40 rejects 41 characters" $(grep -q no <<<"$out"; echo $?)
run_clean "is_hex40 ABCDEF0123456789abcdef0123456789abcdef01 || echo no"
check "is_hex40 rejects uppercase" $(grep -q no <<<"$out"; echo $?)
run_clean 'is_hex40 "" || echo no'
check "is_hex40 rejects the empty string" $(grep -q no <<<"$out"; echo $?)

# load_versions
cat >"$WORK/versions.env" <<'EOF'
# a comment

PDFIUM_BRANCH=chromium/8086
TEST_LITERAL=a$(false)b
EOF
run_clean 'load_versions; echo "$PDFIUM_BRANCH $TEST_LITERAL"' VERSIONS_FILE="$WORK/versions.env"
check "load_versions exports keys and skips comments and blank lines" $(grep -qxF 'chromium/8086 a$(false)b' <<<"$out"; echo $?)
check "load_versions never evaluates a value" $([ "$code" -eq 0 ]; echo $?)
run_clean 'load_versions; echo "$PDFIUM_BRANCH"' VERSIONS_FILE="$WORK/versions.env" PDFIUM_BRANCH=chromium/1111
check "an already-set variable wins over versions.env" $(grep -qxF 'chromium/1111' <<<"$out"; echo $?)
printf 'KEY = value\n' >"$WORK/bad1.env"
run_clean 'load_versions' VERSIONS_FILE="$WORK/bad1.env"
check "load_versions rejects spaces around =" $([ "$code" -eq 2 ] && grep -q "bad line" <<<"$out"; echo $?)
printf 'KEY=two words\n' >"$WORK/bad2.env"
run_clean 'load_versions' VERSIONS_FILE="$WORK/bad2.env"
check "load_versions rejects a value with spaces" $([ "$code" -eq 2 ]; echo $?)
printf 'lowercase=1\n' >"$WORK/bad3.env"
run_clean 'load_versions' VERSIONS_FILE="$WORK/bad3.env"
check "load_versions rejects a lowercase key" $([ "$code" -eq 2 ]; echo $?)
run_clean 'load_versions' VERSIONS_FILE="$WORK/missing.env"
check "load_versions exits 2 when the file is missing" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "common-test: $failures failure(s)"; exit 1; fi
echo "common-test: all passed"
