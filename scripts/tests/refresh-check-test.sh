#!/usr/bin/env bash
# Self-test for scripts/refresh-check.sh with canned branch lists and a canned Chrome Releases feed
# (no network). The pin in these tests is chromium/8086, adopted on 2026-07-01.
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="$PWD/scripts/refresh-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/refresh-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

# On a CI runner GITHUB_STEP_SUMMARY is already set; a due-refresh case here would write an invented
# "PDFium refresh is due" block into the real job summary. Nothing inherited may leak into these runs.
unset GITHUB_STEP_SUMMARY PDFIUM_BRANCH VERSIONS_FILE REFRESH_BRANCHES_FILE REFRESH_FEED_FILE REFRESH_FEED_PAGES_PREFIX \
  REFRESH_PIN_DATE REFRESH_TODAY REFRESH_MAX_AGE_DAYS REFRESH_FEED_URL PDFIUM_URL

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

printf 'PDFIUM_BRANCH=chromium/8086\nMACOS_MIN=27.0\nIOS_MIN=27.0\n' >"$WORK/versions.env"
printf 'aaa\trefs/heads/chromium/8086\nbbb\trefs/heads/chromium/7999\n' >"$WORK/branches-current.txt"
printf 'aaa\trefs/heads/chromium/8086\nccc\trefs/heads/chromium/8100\nbbb\trefs/heads/chromium/7999\n' >"$WORK/branches-newer.txt"
: >"$WORK/branches-empty.txt"

entry() { # <published date> <text>
  printf "<entry><id>x</id><published>%sT10:00:00.000-07:00</published><title type='text'>Stable Channel Update for Desktop</title><content type='html'>%s</content></entry>" "$1" "$2"
}
{ printf "<feed>"; entry 2026-09-20 "Fixes: use after free in the PDF reader"; entry 2026-06-10 "High CVE-2026-1: Use after free in PDFium. Reported by someone"; printf "</feed>"; } >"$WORK/feed-quiet.xml"
{ printf "<feed>"; entry 2026-09-20 "High CVE-2026-2: Out of bounds read in PDFium. Reported by someone"; entry 2026-06-10 "old"; printf "</feed>"; } >"$WORK/feed-security.xml"
{ printf "<feed>"; entry 2026-09-20 "Fixes: use after free in the PDF reader"; printf "</feed>"; } >"$WORK/feed-none.xml"
{ printf "<feed>"; entry 2026-09-20 "High CVE-2026-3: Use after free in PDF. Reported by someone"; printf "</feed>"; } >"$WORK/feed-security-pdf.xml"
{ printf "<feed>"; entry 2026-09-20 "Fixes in PDFs of all sizes and in PDFKit wrappers"; printf "</feed>"; } >"$WORK/feed-lookalike.xml"
printf 'not a feed at all' >"$WORK/feed-broken.xml"

VFILE="$WORK/versions.env"
run() { # <branches file> <feed file> <pin date> <today> -> sets $out, $code
  set +e
  out="$(VERSIONS_FILE="$VFILE" REFRESH_BRANCHES_FILE="$1" REFRESH_FEED_FILE="$2" REFRESH_PIN_DATE="$3" REFRESH_TODAY="$4" "$SCRIPT" 2>&1)"
  code=$?
  set -e
}

run "$WORK/branches-current.txt" "$WORK/feed-quiet.xml" 2026-07-01 2026-10-09
check "pin is the newest branch and no new security note: no refresh (exit 0)" $([ "$code" -eq 0 ] && grep -q "no refresh due" <<<"$out"; echo $?)

run "$WORK/branches-newer.txt" "$WORK/feed-quiet.xml" 2026-09-01 2026-10-09
check "behind but the pin is only 38 days old: no refresh (exit 0)" $([ "$code" -eq 0 ] && grep -q "age_days=38 behind=true" <<<"$out"; echo $?)

run "$WORK/branches-newer.txt" "$WORK/feed-quiet.xml" 2026-07-11 2026-10-09
check "behind and exactly 90 days old: refresh due (exit 1)" $([ "$code" -eq 1 ] && grep -q "age_days=90" <<<"$out" && grep -q "chromium/8100" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-none.xml" 2026-01-01 2026-10-09
check "an old pin that is still the newest branch is not stale (exit 0)" $([ "$code" -eq 0 ]; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-security.xml" 2026-07-01 2026-10-09
check "a Chrome security note about PDFium after the pin date: refresh due (exit 1)" $([ "$code" -eq 1 ] && grep -q "security fix in PDF or PDFium" <<<"$out" && grep -q "2026-09-20" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-security-pdf.xml" 2026-07-01 2026-10-09
check "a note that says 'in PDF' (Chrome's current component name) counts too (exit 1)" $([ "$code" -eq 1 ] && grep -q "security fix in PDF or PDFium" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-lookalike.xml" 2026-07-01 2026-10-09
check "words that only start with 'in PDF' (in PDFs, in PDFKit) are not a security note (exit 0)" $([ "$code" -eq 0 ]; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-security.xml" 2026-09-25 2026-10-09
check "the same note dated before a newer pin does not count (exit 0)" $([ "$code" -eq 0 ]; echo $?)

run "$WORK/branches-empty.txt" "$WORK/feed-quiet.xml" 2026-07-01 2026-10-09
check "an empty branch list fails loudly (exit 3)" $([ "$code" -eq 3 ]; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-broken.xml" 2026-07-01 2026-10-09
check "a feed with no entries fails loudly (exit 3)" $([ "$code" -eq 3 ]; echo $?)

run "$WORK/branches-current.txt" "$WORK/nowhere.xml" 2026-07-01 2026-10-09
check "an unreadable feed fails loudly (exit 3)" $([ "$code" -eq 3 ]; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-quiet.xml" "yesterday" 2026-10-09
check "a malformed pin date fails loudly (exit 3)" $([ "$code" -eq 3 ]; echo $?)

printf 'PDFIUM_BRANCH=main\n' >"$WORK/bad-versions.env"
set +e
out="$(VERSIONS_FILE="$WORK/bad-versions.env" REFRESH_BRANCHES_FILE="$WORK/branches-current.txt" REFRESH_FEED_FILE="$WORK/feed-quiet.xml" REFRESH_PIN_DATE=2026-07-01 REFRESH_TODAY=2026-10-09 "$SCRIPT" 2>&1)"
code=$?
set -e
check "a pin that is not chromium/NNNN is a usage error (exit 2)" $([ "$code" -eq 2 ]; echo $?)

# --- branch numbers compare as numbers, not as text (R7): chromium/10000 is newer than chromium/9999 ---
printf 'PDFIUM_BRANCH=chromium/9999\n' >"$WORK/versions-9999.env"
printf 'a\trefs/heads/chromium/9999\nb\trefs/heads/chromium/10000\nc\trefs/heads/chromium/9998\n' >"$WORK/branches-10000.txt"
VFILE="$WORK/versions-9999.env"
run "$WORK/branches-10000.txt" "$WORK/feed-quiet.xml" 2026-07-01 2026-10-09
VFILE="$WORK/versions.env"
check "chromium/10000 is newer than chromium/9999: newest=chromium/10000 behind=true" $([ "$code" -eq 1 ] && grep -q "newest=chromium/10000 pin_date=2026-07-01 age_days=100 behind=true" <<<"$out"; echo $?)

# --- the pin date comes from git history when REFRESH_PIN_DATE is not given (R7), and a shallow clone is refused (R8) ---
GREPO="$WORK/gitrepo"
mkdir -p "$GREPO/scripts"
cp "$PWD/scripts/refresh-check.sh" "$PWD/scripts/common.sh" "$GREPO/scripts/"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
gitr() { git -C "$GREPO" -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
commit_on() { # <YYYY-MM-DD> <message>: commit everything staged with that author and committer date
  GIT_AUTHOR_DATE="${1}T12:00:00+0000" GIT_COMMITTER_DATE="${1}T12:00:00+0000" gitr commit -q -m "$2"
}
git -C "$GREPO" init -q -b main
printf 'PDFIUM_BRANCH=chromium/7999\nMACOS_MIN=27.0\n' >"$GREPO/versions.env"
gitr add -A
commit_on 2026-01-05 "first pin"
printf 'PDFIUM_BRANCH=chromium/8086\nMACOS_MIN=27.0\n' >"$GREPO/versions.env"
gitr add -A
commit_on 2026-07-01 "move the pin to 8086"
printf 'PDFIUM_BRANCH=chromium/8086\nMACOS_MIN=27.1\n' >"$GREPO/versions.env"
gitr add -A
commit_on 2026-10-01 "change an unrelated pin"

set +e
out="$(REFRESH_BRANCHES_FILE="$WORK/branches-newer.txt" REFRESH_FEED_FILE="$WORK/feed-quiet.xml" REFRESH_TODAY=2026-10-09 "$GREPO/scripts/refresh-check.sh" 2>&1)"
code=$?
set -e
check "without REFRESH_PIN_DATE the pin date is that of the commit that changed PDFIUM_BRANCH, not of the newest commit" $([ "$code" -eq 1 ] && grep -q "pin_date=2026-07-01 age_days=100 behind=true" <<<"$out"; echo $?)

git clone -q --depth 1 "file://$GREPO" "$WORK/shallow"
check "the test clone really is shallow" $([ "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository)" = true ]; echo $?)
set +e
out="$(REFRESH_BRANCHES_FILE="$WORK/branches-newer.txt" REFRESH_FEED_FILE="$WORK/feed-quiet.xml" REFRESH_TODAY=2026-10-09 "$WORK/shallow/scripts/refresh-check.sh" 2>&1)"
code=$?
set -e
check "a shallow clone cannot give the pin date: fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "shallow" <<<"$out" && grep -q "fetch-depth: 0" <<<"$out"; echo $?)

GITHUB_STEP_SUMMARY="$WORK/summary.md"
export GITHUB_STEP_SUMMARY
run "$WORK/branches-newer.txt" "$WORK/feed-quiet.xml" 2026-07-11 2026-10-09
check "a due refresh is also written to the job summary" $(grep -q "PDFium refresh is due" "$WORK/summary.md"; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "refresh-check-test: $failures failure(s)"
  exit 1
fi
echo "refresh-check-test: all passed"
