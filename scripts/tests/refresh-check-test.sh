#!/usr/bin/env bash
# Self-test for scripts/refresh-check.sh with canned branch lists and a canned Chrome Releases feed
# (no network: further feed pages come from files, and the real download path runs against a fake
# download tool that is first on PATH). The pin in these tests is chromium/8086, adopted on 2026-07-01.
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
  REFRESH_PIN_DATE REFRESH_TODAY REFRESH_MAX_AGE_DAYS REFRESH_FEED_MAX_PAGES REFRESH_FEED_URL PDFIUM_URL

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
{ printf "<feed>"; entry 2026-09-20 "Fixes: use after free in the PDF reader"; entry 2025-12-01 "old"; printf "</feed>"; } >"$WORK/feed-none.xml"
{ printf "<feed>"; entry 2026-09-20 "High CVE-2026-3: Use after free in PDF. Reported by someone"; entry 2025-12-01 "old"; printf "</feed>"; } >"$WORK/feed-security-pdf.xml"
{ printf "<feed>"; entry 2026-09-20 "Fixes in PDFs of all sizes and in PDFKit wrappers"; entry 2025-12-01 "old"; printf "</feed>"; } >"$WORK/feed-lookalike.xml"
printf 'not a feed at all' >"$WORK/feed-broken.xml"
# An entry with an <updated> date but no <published> date, or an <entry> of some other shape.
printf "<feed><entry><id>x</id><updated>2026-09-20T10:00:00.000-07:00</updated><title type='text'>Stable Channel Update</title><content type='html'>High CVE-2026-4: Use after free in PDFium. Reported by someone</content></entry></feed>" >"$WORK/feed-nodates.xml"
printf "<feed><entry><id>x</id><updated>2026-09-20T10:00:00.000-07:00</updated><title type='text'>Stable Channel Update</title><content type='html'>Fixes in the printer dialog</content></entry></feed>" >"$WORK/feed-nodates-plain.xml"
# One dated entry that reaches back before the pin, plus an undated one that talks about a PDF fix.
{ printf "<feed>"; entry 2026-06-10 "old"; printf "<entry><id>y</id><updated>2026-09-20T10:00:00.000-07:00</updated><content type='html'>High CVE-2026-5: Use after free in PDF. Reported by someone</content></entry></feed>"; } >"$WORK/feed-undated-note.xml"
# ... and one that is undated but says nothing about PDF.
{ printf "<feed>"; entry 2026-06-10 "old"; printf "<entry><id>z</id><updated>2026-09-20T10:00:00.000-07:00</updated><content type='html'>Fixes in the printer dialog</content></entry></feed>"; } >"$WORK/feed-undated-other.xml"
# The newest entries only: nothing in them is older than the pin date 2026-07-01.
{ printf "<feed>"; entry 2026-09-20 "Fixes: use after free in the PDF reader"; entry 2026-09-10 "more"; printf "</feed>"; } >"$WORK/feed-recent.xml"
{ printf "<feed>"; entry 2026-07-01 "exactly the pin date"; printf "</feed>"; } >"$WORK/feed-on-pin-date.xml"
# Pages 2 and 3 of a longer feed (the Nth page is read from <prefix><N>.xml).
{ printf "<feed>"; entry 2026-09-05 "High CVE-2026-6: Use after free in PDF. Reported by someone"; entry 2026-06-10 "old"; printf "</feed>"; } >"$WORK/pg-note-2.xml"
{ printf "<feed>"; entry 2026-09-05 "Fixes: nothing about the library"; entry 2026-06-10 "old"; printf "</feed>"; } >"$WORK/pg-quiet-2.xml"
{ printf "<feed>"; entry 2026-08-20 "still newer than the pin"; printf "</feed>"; } >"$WORK/pg-short-2.xml"
{ printf "<feed>"; entry 2026-08-01 "still newer than the pin"; entry 2026-07-20 "and again"; printf "</feed>"; } >"$WORK/pg-short-3.xml"
{ printf "<feed>"; entry 2026-06-10 "old"; printf "</feed>"; } >"$WORK/pg-short-4.xml"
printf '<feed></feed>' >"$WORK/pg-empty-2.xml"

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

# The feed is the Chrome Releases blog, which also carries ChromeOS and LTS notes; the check matches them on
# purpose, so the message must name the blog and say so, not claim the hit is a stable desktop release note.
check "the security message names the Chrome Releases blog and the dated posts (exit 1)" \
  $([ "$code" -eq 1 ] && grep -q "Chrome Releases blog posts dated 2026-09-20 mention a security fix in PDF or PDFium after the pin date 2026-07-01" <<<"$out"; echo $?)
check "the security message says ChromeOS and LTS notes count too, and no longer says 'stable release notes'" \
  $(grep -q "ChromeOS and LTS" <<<"$out" && ! grep -qi "stable release note" <<<"$out"; echo $?)

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

# --- the security message names a remedy that can clear the condition (R5) ---
# A rebuild from the tip of the same branch leaves the pin date alone, so the same note would fail every week.
run "$WORK/branches-newer.txt" "$WORK/feed-security.xml" 2026-09-01 2026-10-09
check "a security note while a newer branch exists: the remedy is moving the pin to it, never a rebuild (exit 1)" $([ "$code" -eq 1 ] && grep -q "Move versions.env to chromium/8100" <<<"$out" && ! grep -qi "rebuild" <<<"$out" && ! grep -q "tip of" <<<"$out"; echo $?)
run "$WORK/branches-current.txt" "$WORK/feed-security.xml" 2026-07-01 2026-10-09
check "a security note while the pin is already the newest branch: says so, no rebuild advice (exit 1)" $([ "$code" -eq 1 ] && grep -q "already the newest" <<<"$out" && ! grep -qi "rebuild" <<<"$out" && ! grep -q "move to chromium/8086" <<<"$out"; echo $?)

# --- the feed must have been read, and read back to the pin date (R1) ---
run "$WORK/branches-current.txt" "$WORK/feed-nodates.xml" 2026-07-01 2026-10-09
check "entries without any parseable <published> date fail loudly, never 'no security note' (exit 3)" $([ "$code" -eq 3 ] && grep -q "parseable" <<<"$out" && ! grep -q "no refresh due" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-nodates-plain.xml" 2026-07-01 2026-10-09
check "entries without any parseable <published> date and no PDF text fail loudly too (exit 3)" $([ "$code" -eq 3 ] && grep -q "carries a parseable <published> date" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-undated-note.xml" 2026-07-01 2026-10-09
check "an undated entry that mentions a PDF fix cannot be compared with the pin date: fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "no parseable <published> date" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-undated-other.xml" 2026-07-01 2026-10-09
check "an undated entry that says nothing about PDF does not stop the check (exit 0)" $([ "$code" -eq 0 ] && grep -q "no refresh due" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-recent.xml" 2026-07-01 2026-10-09
check "a feed whose oldest entry is newer than the pin date and has no further page fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "pin date 2026-07-01" <<<"$out" && ! grep -q "no refresh due" <<<"$out"; echo $?)

run "$WORK/branches-current.txt" "$WORK/feed-on-pin-date.xml" 2026-07-01 2026-10-09
check "an entry dated exactly the pin date does not yet reach back before it (exit 3)" $([ "$code" -eq 3 ]; echo $?)

# run_pages <first page> <pages prefix> <pin date> -> sets $out, $code; page N (2 and up) is read from <prefix>N.xml
run_pages() {
  set +e
  out="$(VERSIONS_FILE="$VFILE" REFRESH_BRANCHES_FILE="$WORK/branches-current.txt" REFRESH_FEED_FILE="$1" REFRESH_FEED_PAGES_PREFIX="$2" REFRESH_PIN_DATE="$3" REFRESH_TODAY=2026-10-09 REFRESH_FEED_MAX_PAGES="${4:-30}" "$SCRIPT" 2>&1)"
  code=$?
  set -e
}
run_pages "$WORK/feed-recent.xml" "$WORK/pg-note-" 2026-07-01
check "paging: a PDF note that is only on page 2 is found (exit 1, dated 2026-09-05)" $([ "$code" -eq 1 ] && grep -q "2026-09-05" <<<"$out"; echo $?)
run_pages "$WORK/feed-recent.xml" "$WORK/pg-quiet-" 2026-07-01
check "paging: page 2 reaches back and has no note (exit 0)" $([ "$code" -eq 0 ] && grep -q "no refresh due" <<<"$out"; echo $?)
run_pages "$WORK/feed-recent.xml" "$WORK/nowhere-" 2026-07-01
check "paging: page 2 cannot be read: fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "page 2" <<<"$out"; echo $?)
run_pages "$WORK/feed-recent.xml" "$WORK/pg-empty-" 2026-07-01
check "paging: the feed ends (page 2 has no entries) before the pin date: fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "ends" <<<"$out"; echo $?)
run_pages "$WORK/feed-recent.xml" "$WORK/pg-short-" 2026-07-01
check "paging: pages 2, 3 and 4 are read until one reaches back (exit 0)" $([ "$code" -eq 0 ] && grep -q "no refresh due" <<<"$out"; echo $?)
run_pages "$WORK/feed-recent.xml" "$WORK/pg-short-" 2026-07-01 3
check "paging: a page limit that is reached before the pin date fails loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "limit" <<<"$out"; echo $?)

# --- the real download path (X1), with a fake download tool first on PATH ---
# The fake logs its arguments and serves $FAKE_PAGES/start-<N>.xml, N being the start-index in the URL (1 when
# there is none); anything else fails the way a failed download does.
mkdir -p "$WORK/bin" "$WORK/net-reach" "$WORK/net-page" "$WORK/net-fail" "$WORK/net-none"
cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=""
for a in "$@"; do url="$a"; done
printf '%s\n' "$*" >>"$FAKE_LOG"
n=1
case "$url" in
  *start-index=*) n="${url##*start-index=}"; n="${n%%&*}" ;;
esac
[ -f "$FAKE_PAGES/start-$n.xml" ] || exit 22
cat "$FAKE_PAGES/start-$n.xml"
FAKE
chmod +x "$WORK/bin/curl"
cp "$WORK/feed-quiet.xml" "$WORK/net-reach/start-1.xml"
cp "$WORK/feed-recent.xml" "$WORK/net-page/start-1.xml"
cp "$WORK/pg-note-2.xml" "$WORK/net-page/start-3.xml"
cp "$WORK/feed-recent.xml" "$WORK/net-fail/start-1.xml"

run_net() { # <pages dir> -> sets $out, $code; $WORK/curl.log gets one line per download
  : >"$WORK/curl.log"
  set +e
  out="$(PATH="$WORK/bin:$PATH" FAKE_PAGES="$1" FAKE_LOG="$WORK/curl.log" VERSIONS_FILE="$VFILE" REFRESH_BRANCHES_FILE="$WORK/branches-current.txt" REFRESH_PIN_DATE=2026-07-01 REFRESH_TODAY=2026-10-09 "$SCRIPT" 2>&1)"
  code=$?
  set -e
}
run_net "$WORK/net-reach"
check "the default feed URL is the Blogger feed itself: https, max-results=50, redirect=false" $([ "$code" -eq 0 ] && [ "$(wc -l <"$WORK/curl.log")" -eq 1 ] && grep -q 'https://chromereleases.googleblog.com/feeds/posts/default?max-results=50&redirect=false$' "$WORK/curl.log"; echo $?)
check "the download refuses any redirect to plain http" $(grep -q -e '--proto-redir =https' "$WORK/curl.log"; echo $?)

run_net "$WORK/net-page"
check "the second page is asked for at start-index = entries seen + 1 (exit 1, note from page 2)" $([ "$code" -eq 1 ] && [ "$(wc -l <"$WORK/curl.log")" -eq 2 ] && sed -n 2p "$WORK/curl.log" | grep -q 'start-index=3$' && grep -q "2026-09-05" <<<"$out"; echo $?)
check "every page download refuses a redirect to plain http" $([ "$(grep -c -e '--proto-redir =https' "$WORK/curl.log")" -eq 2 ]; echo $?)

run_net "$WORK/net-fail"
check "a page whose download fails stops the check loudly (exit 3)" $([ "$code" -eq 3 ] && grep -q "could not download" <<<"$out"; echo $?)
check "a failing page 2 download says why page 2 was needed" $(grep -q "could not download page 2 of the Chrome Releases feed (page 2 is needed because the oldest entry read so far, dated 2026-09-10," <<<"$out"; echo $?)

# The very first download has no reason to give: the message must end cleanly, never in empty parentheses.
run_net "$WORK/net-none"
check "a failing page 1 download stops the check loudly (exit 3, a clean message)" \
  $([ "$code" -eq 3 ] && grep -q "error: could not download page 1 of the Chrome Releases feed$" <<<"$out" && ! grep -qF '()' <<<"$out"; echo $?)

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
