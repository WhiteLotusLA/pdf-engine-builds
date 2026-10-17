#!/usr/bin/env bash
# shellcheck disable=SC2046
# Self-test for scripts/pdfium-checkout.sh with a fake git and a fake gclient (no network, no download).
# Review focus: a bogus PDFIUM_BRANCH must fail with a clear message instead of building something else.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/pdfium-checkout.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfium-checkout-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
DEPOT_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BRANCH_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

check() { # <label> <status of the condition, 0 = true>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >>"$FAKE_LOG"
if [ "$1" = "-C" ]; then shift 2; fi
case "$1" in
  ls-remote)
    [ "${FAKE_NET_DOWN:-0}" = "1" ] && exit 128
    pattern="${!#}"
    found=1
    for b in $FAKE_BRANCHES; do
      case "refs/heads/$b" in
        $pattern) printf '%s\trefs/heads/%s\n' "$FAKE_BRANCH_SHA" "$b"; found=0 ;;
      esac
    done
    case " $* " in
      *" --exit-code "*) [ "$found" -ne 0 ] && exit 2 ;;
    esac
    exit 0
    ;;
  clone)
    mkdir -p "${!#}/.git"
    printf '#!/usr/bin/env bash\necho "bootstrap ran" >>"$FAKE_LOG"\n' >"${!#}/update_depot_tools"
    chmod +x "${!#}/update_depot_tools"
    exit 0
    ;;
  fetch | checkout) exit 0 ;;
  rev-parse) echo "${FAKE_HEAD:-$FAKE_BRANCH_SHA}"; exit 0 ;;
esac
exit 0
FAKE
cat >"$WORK/bin/gclient" <<'FAKE'
#!/usr/bin/env bash
echo "gclient $* (cwd $(basename "$PWD"))" >>"$FAKE_LOG"
[ "${FAKE_GCLIENT_FAIL:-0}" = "1" ] && exit 1
if [ "$1" = "sync" ]; then mkdir -p pdfium && : >pdfium/BUILD.gn; fi
exit 0
FAKE
chmod +x "$WORK/bin/git" "$WORK/bin/gclient"

cat >"$WORK/versions.env" <<EOF
PDFIUM_BRANCH=chromium/8086
DEPOT_TOOLS_COMMIT=$DEPOT_SHA
EOF

# run <extra env assignments...>: fresh work dir and log each time; sets $out, $code
run() {
  rm -rf "$WORK/w"
  : >"$WORK/log"
  set +e
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" WORK_DIR="$WORK/w" VERSIONS_FILE="$WORK/versions.env" \
    GIT_BIN="$WORK/bin/git" GCLIENT_BIN="$WORK/bin/gclient" FAKE_LOG="$WORK/log" \
    FAKE_BRANCHES="chromium/8085 chromium/8086" FAKE_BRANCH_SHA="$BRANCH_SHA" "$@" "$SCRIPT" 2>&1)"
  code=$?
  set -e
}
logged() { grep -q -- "$1" "$WORK/log"; }

# --- malformed pins never reach git or gclient ---
for bad in "chromium/99999" "chromium/80" "main" "-rf" "chromium/8086;ls" "refs/heads/chromium/8086"; do
  run PDFIUM_BRANCH="$bad"
  check "PDFIUM_BRANCH='$bad' exits 2 with a clear message and runs nothing" \
    $([ "$code" -eq 2 ] && grep -q "must look like chromium/8086" <<<"$out" && [ ! -s "$WORK/log" ]; echo $?)
done

# --- well formed but not upstream ---
run PDFIUM_BRANCH="chromium/1234"
check "a branch that does not exist upstream exits 3" $([ "$code" -eq 3 ]; echo $?)
check "the message names the branch and lists the newest real ones" \
  $(grep -q "has no branch 'chromium/1234'" <<<"$out" && grep -q "chromium/8085 chromium/8086" <<<"$out"; echo $?)
check "nothing was cloned and gclient never ran" $(! logged "git clone" && ! logged "gclient"; echo $?)
check "no .gclient file was written" $([ ! -e "$WORK/w/.gclient" ]; echo $?)

run FAKE_NET_DOWN=1
check "an unreachable upstream exits 4, not 3" $([ "$code" -eq 4 ] && grep -q "could not reach" <<<"$out"; echo $?)

# --- the pin in versions.env is used when nothing overrides it ---
run
check "a good pin exits 0" $([ "$code" -eq 0 ]; echo $?)
check "depot_tools is checked out at the pinned commit, bootstrapped, and pinned again" \
  $([ "$(grep -c "checkout --quiet $DEPOT_SHA" "$WORK/log")" -eq 2 ] && logged "bootstrap ran"; echo $?)
check "gclient syncs origin/chromium/8086 with no history" $(logged "gclient sync -r origin/chromium/8086 --no-history --shallow"; echo $?)
check ".gclient selects the small configuration and the mac target" \
  $(grep -q '"checkout_configuration": "small"' "$WORK/w/.gclient" && grep -q "target_os = \[ 'mac' \]" "$WORK/w/.gclient"; echo $?)
check ".gclient is unmanaged" $(grep -q '"managed": False' "$WORK/w/.gclient"; echo $?)
check "the checked-out commit is recorded" $([ "$(cat "$WORK/w/pdfium-head.txt")" = "$BRANCH_SHA" ]; echo $?)

run PDFIUM_TARGET_OS_LIST="mac ios"
check "PDFIUM_TARGET_OS_LIST adds ios" $(grep -q "target_os = \[ 'mac', 'ios' \]" "$WORK/w/.gclient"; echo $?)

run PDFIUM_BRANCH="chromium/8085"
check "an override in the environment beats versions.env" $(logged "gclient sync -r origin/chromium/8085"; echo $?)

# --- failures after the check ---
run FAKE_HEAD="cccccccccccccccccccccccccccccccccccccccc"
check "a checkout that is not the branch tip exits 5" $([ "$code" -eq 5 ] && grep -q "is not the tip of chromium/8086" <<<"$out"; echo $?)

run FAKE_GCLIENT_FAIL=1
check "a failing gclient sync exits 4" $([ "$code" -eq 4 ] && grep -q "gclient sync failed" <<<"$out"; echo $?)

run DEPOT_TOOLS_COMMIT="not-a-sha"
check "a malformed DEPOT_TOOLS_COMMIT exits 2" $([ "$code" -eq 2 ]; echo $?)

if [ "$failures" -gt 0 ]; then echo "pdfium-checkout-test: $failures failure(s)"; exit 1; fi
echo "pdfium-checkout-test: all passed"
