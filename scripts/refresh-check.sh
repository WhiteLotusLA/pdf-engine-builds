#!/usr/bin/env bash
# Usage: scripts/refresh-check.sh
#
# Decides whether the PDFium pin in versions.env is due for a refresh. The pin is due when
#   (a) a newer upstream chromium/NNNN branch exists AND the pin was adopted REFRESH_MAX_AGE_DAYS
#       (default 90) or more days ago, or
#   (b) a Chrome release note published after the pin date lists a security fix "in PDFium" (older
#       notes) or "in PDF" (the component name Chrome uses now).
# A pin that is still the newest branch is never "too old" on age alone. If the data cannot be
# fetched or read the script fails (exit 3): a check that could not run must not look like a pass.
#
# The security half reads the Chrome Releases feed newest entry first, and keeps reading pages
# (start-index = entries seen + 1) until it has seen an entry older than the pin date, so that "no
# security note since the pin" is a statement about the whole interval and not about the newest 50
# posts. It fails (exit 3) when no entry carries a parseable <published> date, when an entry that
# mentions a PDF fix has no date to compare, when a page cannot be read, when the feed ends before it
# reaches back to the pin date, and when it would need more than REFRESH_FEED_MAX_PAGES pages.
#
# Environment (all optional; the self-test sets the first six so that it needs no network):
#   REFRESH_BRANCHES_FILE     output of `git ls-remote --heads <pdfium url> 'refs/heads/chromium/*'`
#   REFRESH_FEED_FILE         the first page of the Chrome Releases Atom feed
#   REFRESH_FEED_PAGES_PREFIX with REFRESH_FEED_FILE: page N (2 and up) is read from <prefix>N.xml
#   REFRESH_PIN_DATE          YYYY-MM-DD the pin was adopted (default: date of the last commit that changed
#                             the PDFIUM_BRANCH line of versions.env; needs full history, not a shallow clone)
#   REFRESH_TODAY             YYYY-MM-DD (default: today, UTC)
#   REFRESH_FEED_MAX_PAGES    most feed pages to read (default 30)
#   REFRESH_MAX_AGE_DAYS      default 90
#   PDFIUM_URL                default https://pdfium.googlesource.com/pdfium.git
#   REFRESH_FEED_URL          default https://chromereleases.googleblog.com/feeds/posts/default?max-results=50&redirect=false
#                             (without redirect=false Blogger answers 302 to a plain-http FeedBurner mirror that
#                             ignores max-results and start-index; the download also refuses any redirect to http)
# Exit codes: 0 no refresh due, 1 refresh due (reasons printed and added to $GITHUB_STEP_SUMMARY),
#             2 tool missing or bad pin, 3 data could not be fetched or read.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions
require_env PDFIUM_BRANCH
branch_re='^chromium/([0-9]{4})$'
[[ "$PDFIUM_BRANCH" =~ $branch_re ]] || die 2 "PDFIUM_BRANCH must look like chromium/8086, got '$PDFIUM_BRANCH'"
PINNED="${BASH_REMATCH[1]}"

MAX_AGE="${REFRESH_MAX_AGE_DAYS:-90}"
PDFIUM_URL="${PDFIUM_URL:-https://pdfium.googlesource.com/pdfium.git}"
FEED_URL="${REFRESH_FEED_URL:-https://chromereleases.googleblog.com/feeds/posts/default?max-results=50&redirect=false}"
MAX_PAGES="${REFRESH_FEED_MAX_PAGES:-30}"
pages_re='^[1-9][0-9]*$'
[[ "$MAX_PAGES" =~ $pages_re ]] || die 2 "REFRESH_FEED_MAX_PAGES must be a positive number, got '$MAX_PAGES'"
TODAY="${REFRESH_TODAY:-$(date -u +%Y-%m-%d)}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/refresh-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- the branches ---
if [ -n "${REFRESH_BRANCHES_FILE:-}" ]; then
  cp "$REFRESH_BRANCHES_FILE" "$TMP/branches.txt" || die 3 "cannot read $REFRESH_BRANCHES_FILE"
else
  require_cmd git
  git ls-remote --heads "$PDFIUM_URL" 'refs/heads/chromium/*' >"$TMP/branches.txt" 2>/dev/null \
    || die 3 "could not list the branches of $PDFIUM_URL"
fi
NEWEST="$(sed -n 's#.*refs/heads/chromium/\([0-9][0-9]*\)$#\1#p' "$TMP/branches.txt" | sort -n | tail -1)"
[ -n "$NEWEST" ] || die 3 "no chromium/NNNN branch found in the branch list"

# --- the pin date ---
PIN_DATE="${REFRESH_PIN_DATE:-}"
if [ -z "$PIN_DATE" ]; then
  require_cmd git
  # In a shallow clone the oldest commit looks like it changed every line, so git log would report the
  # date of the tip commit as the pin date: plausible and wrong. Refuse instead of guessing.
  [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null || true)" != true ] \
    || die 3 "this is a shallow clone, so the date the pin was adopted cannot be read from git; check out with fetch-depth: 0 or set REFRESH_PIN_DATE"
  PIN_DATE="$(git -C "$REPO_ROOT" log -1 --format=%cs -G'^PDFIUM_BRANCH=' -- versions.env 2>/dev/null || true)"
fi
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
[[ "$PIN_DATE" =~ $date_re ]] || die 3 "cannot determine the date the pin was adopted (got '$PIN_DATE'); check out with fetch-depth: 0"
[[ "$TODAY" =~ $date_re ]] || die 2 "REFRESH_TODAY must be YYYY-MM-DD"

# --- age in days (civil date to day number, portable awk) ---
AGE="$(awk -v a="$TODAY" -v b="$PIN_DATE" '
  function jdn(s,  p, y, m, d, t, y2, m2) {
    split(s, p, "-"); y = p[1] + 0; m = p[2] + 0; d = p[3] + 0
    t = int((14 - m) / 12); y2 = y + 4800 - t; m2 = m + 12 * t - 3
    return d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045
  }
  BEGIN { print jdn(a) - jdn(b) }')"

# --- the Chrome Releases feed, read back to the pin date ---

# date_before A B: true when A is an earlier YYYY-MM-DD date than B.
date_before() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | sed -n 1p)" = "$1" ]
}

# fetch_feed_page N SEEN OUTFILE: page N of the feed, SEEN being the number of entries read so far.
# WHY (set by the loop below for page 2 and up) says why the page is needed, for the error messages.
fetch_feed_page() {
  local n="$1" seen="$2" out="$3" url sep="?"
  if [ -n "${REFRESH_FEED_FILE:-}" ]; then
    if [ "$n" -eq 1 ]; then
      cp "$REFRESH_FEED_FILE" "$out" || die 3 "cannot read $REFRESH_FEED_FILE"
    else
      [ -n "${REFRESH_FEED_PAGES_PREFIX:-}" ] || die 3 "the Chrome Releases feed has no page $n to read (${WHY:-})"
      cp "${REFRESH_FEED_PAGES_PREFIX}${n}.xml" "$out" 2>/dev/null \
        || die 3 "cannot read page $n of the Chrome Releases feed (${WHY:-})"
    fi
    return 0
  fi
  require_cmd curl
  url="$FEED_URL"
  if [ "$n" -gt 1 ]; then
    case "$url" in *\?*) sep="&" ;; esac
    url="${url}${sep}start-index=$((seen + 1))"
  fi
  # --proto-redir =https: a redirect to plain http is refused, never followed.
  curl -fsSL --proto-redir =https --max-time 60 "$url" >"$out" \
    || die 3 "could not download page $n of the Chrome Releases feed (${WHY:-})"
}

# parse_feed_page FILE: one line per fact about the entries of one feed page:
#   E        an entry
#   D <date> the entry's <published> date
#   S <date> a dated entry published after the pin date that says "in PDF" or "in PDFium"
#   U        an entry that says "in PDF" or "in PDFium" but has no parseable <published> date
# The page is first flattened to one line (a post's HTML may contain newlines), then split so that
# each <entry> ... </entry> is exactly one line for awk.
parse_feed_page() {
  tr '\r\n' '  ' <"$1" | sed 's#<entry#\
<entry#g' | awk -v since="$PIN_DATE" '
    /<entry/ {
      print "E"
      says = (match($0, /in PDF(ium)?[^A-Za-z]/) > 0)
      if (match($0, /<published>[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        d = substr($0, RSTART + 11, 10)
        print "D " d
        if (d > since && says) print "S " d
      } else if (says) {
        print "U"
      }
    }'
}

DATED="$TMP/dated.txt"
NOTES="$TMP/notes.txt"
: >"$DATED"
: >"$NOTES"
seen=0
page=1
WHY=""
while :; do
  fetch_feed_page "$page" "$seen" "$TMP/feed-$page.xml"
  parse_feed_page "$TMP/feed-$page.xml" >"$TMP/parsed-$page.txt"
  count="$(grep -c '^E$' "$TMP/parsed-$page.txt" || true)"
  if [ "$count" -eq 0 ]; then
    [ "$page" -gt 1 ] || die 3 "the Chrome Releases feed has no entries (empty or not an Atom feed)"
    die 3 "the Chrome Releases feed ends at page $((page - 1)) ($seen entries, the oldest dated $OLDEST) without reaching back before the pin date $PIN_DATE"
  fi
  seen=$((seen + count))
  if grep -q '^U$' "$TMP/parsed-$page.txt"; then
    die 3 "an entry in the Chrome Releases feed mentions a PDF fix but has no parseable <published> date, so it cannot be compared with the pin date $PIN_DATE"
  fi
  sed -n 's/^D //p' "$TMP/parsed-$page.txt" >>"$DATED"
  sed -n 's/^S //p' "$TMP/parsed-$page.txt" >>"$NOTES"
  [ -s "$DATED" ] || die 3 "no entry in the Chrome Releases feed carries a parseable <published> date (YYYY-MM-DD), so it cannot be checked against the pin date $PIN_DATE"
  OLDEST="$(LC_ALL=C sort "$DATED" | sed -n 1p)"
  if date_before "$OLDEST" "$PIN_DATE"; then
    break
  fi
  [ "$page" -lt "$MAX_PAGES" ] \
    || die 3 "read $page pages ($seen entries, the oldest dated $OLDEST) without reaching back before the pin date $PIN_DATE; the page limit (REFRESH_FEED_MAX_PAGES=$MAX_PAGES) is reached"
  page=$((page + 1))
  WHY="page $page is needed because the oldest entry read so far, dated $OLDEST, is not older than the pin date $PIN_DATE"
done
SECURITY_DATES="$(LC_ALL=C sort -u "$NOTES" | tr '\n' ' ')"

BEHIND=false
[ "$NEWEST" -gt "$PINNED" ] && BEHIND=true
due=0
reasons=""
if [ "$BEHIND" = true ] && [ "$AGE" -ge "$MAX_AGE" ]; then
  due=1
  reasons="$reasons- The pin chromium/$PINNED is $AGE days old (limit $MAX_AGE) and upstream has chromium/$NEWEST. Move versions.env to the newest branch, refresh the patch series and release.
"
fi
if [ -n "$SECURITY_DATES" ]; then
  due=1
  # The pin date only changes when the PDFIUM_BRANCH line changes, so moving the pin is the only remedy
  # that clears this reason; a rebuild of the same branch would leave it failing every week.
  if [ "$BEHIND" = true ]; then
    remedy="Move versions.env to chromium/$NEWEST, refresh the patch series and release."
  else
    remedy="The pin is already the newest upstream branch (chromium/$PINNED), so there is nothing to move to yet; this stays red until a newer chromium branch exists and the pin moves to it."
  fi
  reasons="$reasons- Chrome stable release notes dated ${SECURITY_DATES% } list a security fix in PDF or PDFium after the pin date $PIN_DATE. $remedy
"
fi

SECURITY=no
[ -z "$SECURITY_DATES" ] || SECURITY=yes
echo "refresh-check: pinned=chromium/$PINNED newest=chromium/$NEWEST pin_date=$PIN_DATE age_days=$AGE behind=$BEHIND security_notes_since_pin=$SECURITY"
if [ "$due" -eq 1 ]; then
  printf 'PDFium refresh is due:\n%s' "$reasons"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### PDFium refresh is due\n\n%s' "$reasons" >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi
echo "refresh-check: no refresh due"
