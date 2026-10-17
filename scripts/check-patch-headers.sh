#!/usr/bin/env bash
# Usage: scripts/check-patch-headers.sh [patch-root]        (default: patches)
# Every .patch file under <patch-root>/*/ must carry a provenance header before its first "diff --git" line:
#   "# Source: ..."   where the patch came from
#   "# License: ..."  the license of what it adds
# and, when it has one, a safe "# Apply-Dir: <relative dir>" (letters, digits, _ . / - ; no "..").
# Exit codes: 0 ok, 1 a patch has a missing or bad header, 2 usage error.
set -euo pipefail

ROOT="${1:-patches}"
if [ ! -d "$ROOT" ]; then
  echo "check-patch-headers: no such directory: $ROOT" >&2
  exit 2
fi

failures=0
checked=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}
dir_re='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'

while IFS= read -r patch; do
  checked=$((checked + 1))
  name="${patch#"$ROOT"/}"
  head_part="$(awk '/^diff --git /{exit} {print}' "$patch")"
  grep -q '^# Source: .' <<<"$head_part" || fail "$name: no '# Source:' header line before the first diff"
  grep -q '^# License: .' <<<"$head_part" || fail "$name: no '# License:' header line before the first diff"
  apply_dir="$(sed -n 's/^# Apply-Dir: //p' <<<"$head_part" | head -1)"
  if [ -n "$apply_dir" ] && [ "$apply_dir" != "." ]; then
    if ! [[ "$apply_dir" =~ $dir_re ]] || [[ "$apply_dir" == *..* ]]; then
      fail "$name: unsafe Apply-Dir '$apply_dir'"
    fi
  fi
  grep -q '^diff --git ' "$patch" || fail "$name: contains no diff"
done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name '*.patch' -type f | LC_ALL=C sort)

if [ "$failures" -gt 0 ]; then
  echo "check-patch-headers: $failures problem(s) in $checked patch file(s)"
  exit 1
fi
echo "check-patch-headers: $checked patch file(s) ok"
