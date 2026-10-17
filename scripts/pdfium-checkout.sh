#!/usr/bin/env bash
# Usage: scripts/pdfium-checkout.sh
# Checks out PDFium at the branch pinned as PDFIUM_BRANCH in versions.env into $WORK_DIR/pdfium
# (default work/pdfium), using depot_tools pinned at DEPOT_TOOLS_COMMIT. There is no default branch:
# a missing, malformed or non-existent branch stops the script before anything is downloaded.
#
# Environment (all optional): WORK_DIR, PDFIUM_TARGET_OS_LIST (default "mac"; the iOS task sets "mac ios"),
# PDFIUM_CHECKOUT_CONFIG (default "small": skips test corpora but keeps Skia, which the EmbedPDF
# redaction code needs), PDFIUM_URL, DEPOT_TOOLS_URL, GIT_BIN and GCLIENT_BIN (the tests replace them).
# Exit codes: 0 ok, 2 bad pin or missing tool, 3 the branch does not exist upstream,
#             4 network, git or gclient failure, 5 the checkout is not the branch that was asked for.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_versions

GIT="${GIT_BIN:-git}"
GCLIENT="${GCLIENT_BIN:-gclient}"
PDFIUM_URL="${PDFIUM_URL:-https://pdfium.googlesource.com/pdfium.git}"
DEPOT_TOOLS_URL="${DEPOT_TOOLS_URL:-https://chromium.googlesource.com/chromium/tools/depot_tools.git}"
TARGET_OS_LIST="${PDFIUM_TARGET_OS_LIST:-mac}"
CONFIG="${PDFIUM_CHECKOUT_CONFIG:-small}"

require_env PDFIUM_BRANCH DEPOT_TOOLS_COMMIT
branch_re='^chromium/[0-9]{4}$'
if ! [[ "$PDFIUM_BRANCH" =~ $branch_re ]]; then
  die 2 "PDFIUM_BRANCH must look like chromium/8086 (four digits), got '$PDFIUM_BRANCH'"
fi
is_hex40 "$DEPOT_TOOLS_COMMIT" || die 2 "DEPOT_TOOLS_COMMIT must be a full 40-character SHA"
os_re='^[a-z]+( [a-z]+)*$'
config_re='^(small|minimal|default)$'
[[ "$TARGET_OS_LIST" =~ $os_re ]] || die 2 "PDFIUM_TARGET_OS_LIST must be lowercase words separated by single spaces"
[[ "$CONFIG" =~ $config_re ]] || die 2 "PDFIUM_CHECKOUT_CONFIG must be small, minimal or default"
require_cmd "$GIT"

# 1. The branch must exist upstream. Ask before cloning anything.
log "checking that $PDFIUM_BRANCH exists upstream"
set +e
branch_line="$("$GIT" ls-remote --exit-code --heads "$PDFIUM_URL" "refs/heads/$PDFIUM_BRANCH" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
  0) ;;
  2)
    newest="$("$GIT" ls-remote --heads "$PDFIUM_URL" 'refs/heads/chromium/*' 2>/dev/null \
      | sed 's#.*refs/heads/##' | sort -t/ -k2 -n | tail -3 | tr '\n' ' ' || true)"
    die 3 "upstream PDFium has no branch '$PDFIUM_BRANCH'; newest branches: ${newest:-unknown}. Fix PDFIUM_BRANCH in versions.env."
    ;;
  *) die 4 "could not reach $PDFIUM_URL (git ls-remote exit $rc)" ;;
esac
expected_sha="$(printf '%s' "$branch_line" | cut -f1)"
is_hex40 "$expected_sha" || die 4 "unexpected git ls-remote output for $PDFIUM_BRANCH"

# 2. depot_tools at the pinned commit, never auto-updated.
DEPOT="$WORK_DIR/depot_tools"
mkdir -p "$WORK_DIR"
if [ ! -d "$DEPOT/.git" ]; then
  log "cloning depot_tools"
  "$GIT" clone --quiet "$DEPOT_TOOLS_URL" "$DEPOT" || die 4 "could not clone depot_tools"
fi
"$GIT" -C "$DEPOT" fetch --quiet origin || die 4 "could not fetch depot_tools"
"$GIT" -C "$DEPOT" checkout --quiet "$DEPOT_TOOLS_COMMIT" || die 4 "depot_tools has no commit $DEPOT_TOOLS_COMMIT"
# With DEPOT_TOOLS_UPDATE=0 depot_tools skips its python and cipd bootstrap, so bootstrap once first, then pin
# again (the bootstrap may move a checkout) and switch automatic updates off for the rest of the run.
log "bootstrapping depot_tools (python and cipd)"
"$DEPOT/update_depot_tools" >/dev/null 2>&1 || die 4 "depot_tools bootstrap failed"
"$GIT" -C "$DEPOT" checkout --quiet "$DEPOT_TOOLS_COMMIT" || die 4 "could not pin depot_tools to $DEPOT_TOOLS_COMMIT after the bootstrap"
export DEPOT_TOOLS_UPDATE=0
export PATH="$DEPOT:$PATH"
require_cmd "$GCLIENT"

# 3. gclient configuration, then sync at origin/<branch>.
targets=""
for os in $TARGET_OS_LIST; do
  targets="$targets'$os', "
done
cat >"$WORK_DIR/.gclient" <<EOF
solutions = [
  {
    "name": "pdfium",
    "url": "$PDFIUM_URL",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_configuration": "$CONFIG",
    },
  },
]
target_os = [ ${targets%, } ]
EOF

log "syncing PDFium $PDFIUM_BRANCH (this downloads several GB)"
(cd "$WORK_DIR" && "$GCLIENT" sync -r "origin/$PDFIUM_BRANCH" --no-history --shallow) \
  || die 4 "gclient sync failed"

# 4. What was checked out must be the branch that was asked for.
[ -f "$WORK_DIR/pdfium/BUILD.gn" ] || die 5 "checkout has no pdfium/BUILD.gn"
head_sha="$("$GIT" -C "$WORK_DIR/pdfium" rev-parse HEAD)"
if [ "$head_sha" != "$expected_sha" ]; then
  die 5 "checked-out commit ${head_sha:0:12} is not the tip of $PDFIUM_BRANCH (${expected_sha:0:12})"
fi
printf '%s\n' "$head_sha" >"$WORK_DIR/pdfium-head.txt"
log "PDFium $PDFIUM_BRANCH at ${head_sha:0:12} is ready in $WORK_DIR/pdfium"
