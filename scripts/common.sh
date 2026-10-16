#!/usr/bin/env bash
# Shared helpers for every script in this repo. Source it, do not run it:
#   . "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# Written for the bash 3.2 that ships with macOS: no mapfile, no associative arrays.

set -euo pipefail

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_SH_DIR/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
export REPO_ROOT SCRIPT_NAME WORK_DIR DIST_DIR

# Status line on stderr.
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

warn() { printf '%s: warning: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# die <exit code> <message...>: print the message and exit with the code.
die() {
  local code="$1"
  shift
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$code"
}

# require_env NAME...: exit 2 and name every variable that is unset or empty.
require_env() {
  local name missing=""
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    die 2 "required environment variable(s) not set:$missing"
  fi
}

# require_cmd TOOL...: exit 2 when a tool is not on PATH.
require_cmd() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die 2 "required tool not found: $tool"
  done
}

# is_hex40 VALUE: true when VALUE is a full 40-character lowercase git SHA.
is_hex40() {
  local re='^[0-9a-f]{40}$'
  [[ "${1:-}" =~ $re ]]
}

# load_versions: read KEY=VALUE lines from versions.env (or $VERSIONS_FILE) and export each key that
# is not already set in the environment, so a caller can override a pin for one run.
# The file is parsed, never sourced: a line that is not a comment, blank or KEY=VALUE is an error.
load_versions() {
  local file="${VERSIONS_FILE:-$REPO_ROOT/versions.env}"
  local line key val
  local re='^([A-Z][A-Z0-9_]*)=([^[:space:]]*)$'
  [ -f "$file" ] || die 2 "versions file not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    [[ "$line" =~ $re ]] || die 2 "bad line in $file (want KEY=VALUE, no spaces): $line"
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if ! printenv "$key" >/dev/null 2>&1; then
      export "$key=$val"
    fi
  done <"$file"
}
