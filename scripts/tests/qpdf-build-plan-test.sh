#!/usr/bin/env bash
# Self-test for scripts/qpdf-build.sh and scripts/qpdf-xcframework.sh that needs no cmake, no
# network and no build: it reads what the build script WOULD run (QB_DRY_RUN=1) and checks the
# flags, plus the failure paths (bad slice, missing source pin, tampered source download,
# missing slice).
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "qpdf-build-plan-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-build-plan-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; }          # has <text> <fixed string>
lacks() { ! grep -qF -- "$2" <<<"$1"; }

dry() { # <slice> [env assignments...] -> prints the plan
  local slice="$1"
  shift
  env QB_DRY_RUN=1 WORK_DIR="$WORK/dry-work" OUT_DIR="$WORK/dry-out" "$@" "$REPO/scripts/qpdf-build.sh" "$slice"
}

for slice in macos-arm64 ios-arm64 iossim-arm64; do
  plan="$(dry "$slice")"
  check "$slice: static only" $(has "$plan" "-DBUILD_SHARED_LIBS=OFF" && has "$plan" "-DBUILD_STATIC_LIBS=ON"; echo $?)
  check "$slice: native crypto required, implicit crypto off" $(has "$plan" "-DUSE_IMPLICIT_CRYPTO=OFF" && has "$plan" "-DREQUIRE_CRYPTO_NATIVE=ON"; echo $?)
  check "$slice: GnuTLS and OpenSSL are never required or enabled" $(lacks "$plan" "-DREQUIRE_CRYPTO_GNUTLS=ON" && lacks "$plan" "-DREQUIRE_CRYPTO_OPENSSL=ON" && lacks "$plan" "-DUSE_IMPLICIT_CRYPTO=ON"; echo $?)
  check "$slice: zlib comes from the SDK" $(has "$plan" "/usr/lib/libz.tbd"; echo $?)
  check "$slice: libjpeg-turbo is static without SIMD, tools or TurboJPEG" $(has "$plan" "-DENABLE_SHARED=0" && has "$plan" "-DWITH_SIMD=0" && has "$plan" "-DWITH_TURBOJPEG=0" && has "$plan" "-DWITH_TOOLS=0"; echo $?)
  check "$slice: configure checks do not link executables" $(has "$plan" "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"; echo $?)
  check "$slice: merged with libtool and checked for TLS symbols" $(has "$plan" "libtool -static" && has "$plan" "check-no-tls-symbols.sh --require-native"; echo $?)
  guard_line="$(grep -n 'qpdf-config-guard.sh' <<<"$plan" | head -1 | cut -d: -f1)"
  build_line="$(grep -n -- '--target libqpdf' <<<"$plan" | head -1 | cut -d: -f1)"
  check "$slice: the config guard runs before the qpdf build" $([ -n "$guard_line" ] && [ -n "$build_line" ] && [ "$guard_line" -lt "$build_line" ]; echo $?)
done

plan="$(dry macos-arm64)"
check "macos: native build, no CMAKE_SYSTEM_NAME" $(has "$plan" "-DCMAKE_OSX_SYSROOT=macosx" && lacks "$plan" "-DCMAKE_SYSTEM_NAME"; echo $?)
plan="$(dry ios-arm64)"
check "ios device: iOS system name and iphoneos SDK" $(has "$plan" "-DCMAKE_SYSTEM_NAME=iOS" && has "$plan" "-DCMAKE_OSX_SYSROOT=iphoneos"; echo $?)
plan="$(dry iossim-arm64)"
check "ios simulator: iOS system name and iphonesimulator SDK" $(has "$plan" "-DCMAKE_SYSTEM_NAME=iOS" && has "$plan" "-DCMAKE_OSX_SYSROOT=iphonesimulator"; echo $?)

plan="$(dry macos-arm64 QB_ALLOW_IMPLICIT_CRYPTO=1)"
check "test-only implicit mode really switches implicit crypto on" $(has "$plan" "-DUSE_IMPLICIT_CRYPTO=ON" && lacks "$plan" "-DREQUIRE_CRYPTO_NATIVE=ON"; echo $?)

# --- failure paths ---
set +e
out="$("$REPO/scripts/qpdf-build.sh" bogus-slice 2>&1)"; code=$?
set -e
check "an unknown slice exits 2 and says so" $([ "$code" -eq 2 ] && has "$out" "unknown slice"; echo $?)
set +e
out="$("$REPO/scripts/qpdf-build.sh" 2>&1)"; code=$?
set -e
check "no slice exits 2" $([ "$code" -eq 2 ]; echo $?)

# A source pin missing from sources.sha256 stops the build before any download.
grep -v 'qpdf-' "$REPO/sources.sha256" >"$WORK/sources-without-qpdf.sha256" || true
set +e
out="$(SOURCES_SHA256_FILE="$WORK/sources-without-qpdf.sha256" QB_DRY_RUN=1 "$REPO/scripts/qpdf-build.sh" macos-arm64 2>&1)"; code=$?
set -e
check "a missing qpdf source pin exits 2 and names the tarball" $([ "$code" -eq 2 ] && has "$out" "no checksum for qpdf-"; echo $?)

# A tampered source download: fake gh serves wrong bytes; the fake cmake is never reached.
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
dir="" pattern=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --pattern) pattern="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'not the real tarball\n' >"$dir/$pattern"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/fakebin/cmake"
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/cmake"
set +e
out="$(PATH="$WORK/fakebin:$PATH" WORK_DIR="$WORK/tamper-work" OUT_DIR="$WORK/tamper-out" "$REPO/scripts/qpdf-build.sh" macos-arm64 2>&1)"; code=$?
set -e
check "a tampered qpdf download exits 3 with a checksum message" $([ "$code" -eq 3 ] && has "$out" "checksum mismatch"; echo $?)
check "the tampered download was deleted and nothing was unpacked" $([ -z "$(find "$WORK/tamper-work" -name '*.tar.gz' 2>/dev/null)" ] && [ -z "$(find "$WORK/tamper-work/src" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; echo $?)

# A good source download: fake gh serves tarballs whose hashes are in a temporary sources.sha256.
# shellcheck source=../../versions.env
. "$REPO/versions.env"
mkdir -p "$WORK/tarballs" "$WORK/pack/qpdf-$QPDF_VERSION" "$WORK/pack/libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
echo "qpdf marker" >"$WORK/pack/qpdf-$QPDF_VERSION/marker.txt"
echo "jpeg marker" >"$WORK/pack/libjpeg-turbo-$LIBJPEG_TURBO_VERSION/marker.txt"
tar -czf "$WORK/tarballs/qpdf-$QPDF_VERSION.tar.gz" -C "$WORK/pack" "qpdf-$QPDF_VERSION"
tar -czf "$WORK/tarballs/libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" -C "$WORK/pack" "libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
(cd "$WORK/tarballs" && shasum -a 256 ./*.tar.gz | sed 's#  \./#  #') >"$WORK/good-sources.sha256"
mkdir -p "$WORK/goodbin"
cat >"$WORK/goodbin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
dir="" pattern=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --pattern) pattern="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FAKE_TARBALLS/$pattern" "$dir/$pattern"
FAKE
chmod +x "$WORK/goodbin/gh"
: >"$WORK/gh.log"
set +e
out="$(PATH="$WORK/goodbin:$PATH" FAKE_GH_LOG="$WORK/gh.log" FAKE_TARBALLS="$WORK/tarballs" SOURCES_SHA256_FILE="$WORK/good-sources.sha256" WORK_DIR="$WORK/good-work" QB_FETCH_ONLY=1 "$REPO/scripts/qpdf-build.sh" macos-arm64 2>&1)"; code=$?
set -e
check "a verified download is unpacked (fetch-only mode, exit 0)" $([ "$code" -eq 0 ] && [ -f "$WORK/good-work/src/qpdf-$QPDF_VERSION/marker.txt" ] && [ -f "$WORK/good-work/src/libjpeg-turbo-$LIBJPEG_TURBO_VERSION/marker.txt" ]; echo $?)
check "both downloads asked GitHub for the tagged release asset of the right repo" $(grep -q -- "release download v$QPDF_VERSION --repo qpdf/qpdf --pattern qpdf-$QPDF_VERSION.tar.gz" "$WORK/gh.log" && grep -q -- "release download $LIBJPEG_TURBO_VERSION --repo libjpeg-turbo/libjpeg-turbo --pattern libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz" "$WORK/gh.log"; echo $?)
: >"$WORK/gh.log"
set +e
out="$(PATH="$WORK/goodbin:$PATH" FAKE_GH_LOG="$WORK/gh.log" FAKE_TARBALLS="$WORK/tarballs" SOURCES_SHA256_FILE="$WORK/good-sources.sha256" WORK_DIR="$WORK/good-work" QB_FETCH_ONLY=1 "$REPO/scripts/qpdf-build.sh" macos-arm64 2>&1)"; code=$?
set -e
check "a second run downloads nothing" $([ "$code" -eq 0 ] && [ ! -s "$WORK/gh.log" ]; echo $?)

# qpdf-xcframework.sh with a missing slice stops before it runs xcodebuild.
mkdir -p "$WORK/partial/qpdf/macos-arm64/Headers/qpdf"
: >"$WORK/partial/qpdf/macos-arm64/libqpdf.a"
: >"$WORK/partial/qpdf/macos-arm64/Headers/qpdf/QPDF.hh"
set +e
out="$(OUT_DIR="$WORK/partial" DIST_DIR="$WORK/partial-dist" "$REPO/scripts/qpdf-xcframework.sh" 2>&1)"; code=$?
set -e
check "an xcframework with a missing slice exits 3 and names the slice" $([ "$code" -eq 3 ] && has "$out" "missing slice ios-arm64"; echo $?)
check "no xcframework or zip was produced" $([ ! -e "$WORK/partial-dist/QPDF.xcframework" ] && [ ! -e "$WORK/partial-dist/QPDF.xcframework.zip" ]; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "qpdf-build-plan-test: $failures failure(s)"
  exit 1
fi
echo "qpdf-build-plan-test: all passed"
