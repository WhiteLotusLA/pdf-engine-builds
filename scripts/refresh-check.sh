#!/usr/bin/env bash
# Usage: scripts/refresh-check.sh
#
# Decides whether the PDFium pin in versions.env is due for a refresh. The pin is due when
#   (a) a newer upstream chromium/NNNN branch exists AND the pin was adopted REFRESH_MAX_AGE_DAYS
#       (default 90) or more days ago, or
#   (b) a Chrome release note published after the pin date lists a security fix "in PDFium" (older
#       notes) or "in PDF" (the component name Chrome uses now).
# A pin that is still the newest branch is never "too old" on age alone. If the data cannot be
# fetched the script fails (exit 3): a check that could not run must not look like a pass.
#
# Environment (all optional; the tests use the first four):
#   REFRESH_BRANCHES_FILE  output of `git ls-remote --heads <pdfium url> 'refs/heads/chromium/*'`
#   REFRESH_FEED_FILE      the Chrome Releases Atom feed
#   REFRESH_PIN_DATE       YYYY-MM-DD the pin was adopted (default: date of the last commit that changed
#                          the PDFIUM_BRANCH line of versions.env; needs full history)
#   REFRESH_TODAY          YYYY-MM-DD (default: today, UTC)
#   REFRESH_MAX_AGE_DAYS   default 90
#   PDFIUM_URL             default https://pdfium.googlesource.com/pdfium.git
#   REFRESH_FEED_URL       default https://chromereleases.googleblog.com/feeds/posts/default?max-results=50
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
FEED_URL="${REFRESH_FEED_URL:-https://chromereleases.googleblog.com/feeds/posts/default?max-results=50}"
TODAY="${REFRESH_TODAY:-$(date -u +%Y-%m-%d)}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/refresh-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- data ---
if [ -n "${REFRESH_BRANCHES_FILE:-}" ]; then
  cp "$REFRESH_BRANCHES_FILE" "$TMP/branches.txt" || die 3 "cannot read $REFRESH_BRANCHES_FILE"
else
  require_cmd git
  git ls-remote --heads "$PDFIUM_URL" 'refs/heads/chromium/*' >"$TMP/branches.txt" 2>/dev/null \
    || die 3 "could not list the branches of $PDFIUM_URL"
fi
NEWEST="$(sed -n 's#.*refs/heads/chromium/\([0-9][0-9]*\)$#\1#p' "$TMP/branches.txt" | sort -n | tail -1)"
[ -n "$NEWEST" ] || die 3 "no chromium/NNNN branch found in the branch list"

if [ -n "${REFRESH_FEED_FILE:-}" ]; then
  cp "$REFRESH_FEED_FILE" "$TMP/feed.xml" || die 3 "cannot read $REFRESH_FEED_FILE"
else
  require_cmd curl
  curl -fsSL --max-time 60 "$FEED_URL" >"$TMP/feed.xml" || die 3 "could not download the Chrome Releases feed"
fi
grep -q '<entry' "$TMP/feed.xml" || die 3 "the Chrome Releases feed has no entries (empty or not an Atom feed)"

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

# --- security notes published after the pin date that mention PDFium ---
# The feed is first flattened to one line (a post's HTML may contain newlines), then split so that
# each <entry> ... </entry> is exactly one line for awk.
SECURITY_DATES="$(tr '\r\n' '  ' <"$TMP/feed.xml" | sed 's#<entry#\
<entry#g' | awk -v since="$PIN_DATE" '
  /<entry/ {
    if (match($0, /<published>[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
      d = substr($0, RSTART + 11, 10)
      if (d > since && match($0, /in PDF(ium)?[^A-Za-z]/) > 0) print d
    }
  }' | sort -u | tr '\n' ' ')"

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
  reasons="$reasons- Chrome stable release notes dated ${SECURITY_DATES% } list a security fix in PDF or PDFium after the pin date $PIN_DATE. Rebuild from the tip of chromium/$PINNED or move to chromium/$NEWEST, then release.
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
