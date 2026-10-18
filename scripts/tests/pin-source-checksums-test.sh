#!/usr/bin/env bash
# Self-test for scripts/pin-source-checksums.sh with a fake gh (no network): the pin is written
# when GitHub's digest and the download agree, and refused (nothing written) when they differ or
# when the asset has no digest.
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pin-sources-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}

printf 'tarball bytes\n' >"$WORK/payload"
GOOD="$(shasum -a 256 "$WORK/payload" | awk '{print $1}')"

# Fake gh. `gh api ... --jq ...` prints $FAKE_DIGEST (or nothing when it is "none");
# `gh release download ... --pattern P --dir D` copies the payload to D/P.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  api)
    if [ "$FAKE_DIGEST" != "none" ]; then printf '%s\n' "$FAKE_DIGEST"; fi
    ;;
  release)
    dir="" pattern=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) dir="$2"; shift 2 ;;
        --pattern) pattern="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$FAKE_PAYLOAD" "$dir/$pattern"
    ;;
esac
FAKE
chmod +x "$WORK/bin/gh"

run() { # <digest> -> sets $out, $code; the output file is $WORK/sources.sha256
  set +e
  out="$(FAKE_DIGEST="$1" FAKE_PAYLOAD="$WORK/payload" GH_BIN="$WORK/bin/gh" SOURCES_SHA256_FILE="$WORK/sources.sha256" "$REPO/scripts/pin-source-checksums.sh" 2>&1)"
  code=$?
  set -e
}

run "sha256:$GOOD"
check "matching digest and download exits 0" $([ "$code" -eq 0 ]; echo $?)
check "both tarballs are recorded with the right hash" $([ "$(grep -c "^$GOOD  " "$WORK/sources.sha256")" -eq 2 ] && grep -q '  qpdf-[0-9.]*\.tar\.gz$' "$WORK/sources.sha256" && grep -q '  libjpeg-turbo-[0-9.]*\.tar\.gz$' "$WORK/sources.sha256"; echo $?)

cp "$WORK/sources.sha256" "$WORK/before.sha256"
run "sha256:$(printf '0%.0s' $(seq 1 64))"
check "a digest that differs from the download exits 3" $([ "$code" -eq 3 ]; echo $?)
check "the existing sources.sha256 is untouched after a refusal" $(cmp -s "$WORK/before.sha256" "$WORK/sources.sha256"; echo $?)

run "none"
check "an asset without a digest exits 3" $([ "$code" -eq 3 ]; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "pin-source-checksums-test: $failures failure(s)"
  exit 1
fi
echo "pin-source-checksums-test: all passed"
