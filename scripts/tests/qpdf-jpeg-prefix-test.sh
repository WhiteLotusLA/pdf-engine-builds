#!/usr/bin/env bash
# Self-test for scripts/qpdf-jpeg-prefix.sh on toy archives: a few lines of C and C++ compiled with
# xcrun clang, no engine build. The toys model the real problem seen in CI run 39083399705: PDFium
# carries Chromium's libjpeg_turbo, whose table jpeg_natural_order is a private external, and qpdf's
# archive has a libjpeg merged in that defines the same name, so an app linking both engines fails with
# "duplicate symbol '_jpeg_natural_order'". The test proves that
#   - the plain merge really fails that link, and the check refuses the plain archive;
#   - the header lists every external and private external definition (weak and common too), and
#     nothing local;
#   - rebuilding the toy libjpeg and compiling the toy qpdf with the header force-included (-include,
#     as scripts/qpdf-build.sh does) gives an archive the check accepts, that links next to the toy
#     PDFium, and whose code still reads its own table;
#   - every half-right archive is refused with a message that names the symbol or member, and a tool
#     failure is never taken for a pass;
#   - scripts/qpdf-build.sh itself, run for real on toy sources with a fake cmake, makes the header from
#     pass 1, compiles pass 2 and qpdf with it, keeps the S11 guards, and stops with exit 6 when either
#     compile goes without the header or the header cannot be made.
# shellcheck disable=SC2046
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "qpdf-jpeg-prefix-test: skipped (needs Xcode tools)"
  exit 0
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
TOOL="$REPO/scripts/qpdf-jpeg-prefix.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-jpeg-prefix-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # <label> <0 when the condition held>
  if [ "$2" -eq 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; } # has <text> <fixed string>
lacks() { ! grep -qF -- "$2" <<<"$1"; }

CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cflags=(-O0 -fcommon -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0)
S="$WORK/src"
mkdir -p "$S" "$WORK/obj"

# --- the toy sources ---
# Toy libjpeg, two members like jutils.c and jerror.c: a table, a hidden helper (a private external), a
# weak function, a common variable, a plain function and a static one (local, so never listed).
cat >"$S/jutils.c" <<'EOF'
const int jpeg_natural_order[4] = { 0, 1, 8, 16 };
__attribute__((visibility("hidden"))) int jpeg_hidden_helper(int i) { return jpeg_natural_order[i]; }
int jround_up(int a, int b) { return ((a + b - 1) / b) * b; }
EOF
cat >"$S/jerror.c" <<'EOF'
int jpeg_hidden_helper(int i);
int jpeg_common_counter;
__attribute__((weak)) int jpeg_weak_hook(void) { return 0; }
static int jpeg_local_only(void) { return 0; }
int jpeg_std_error(void) { jpeg_common_counter++; return jpeg_hidden_helper(1) + jpeg_weak_hook() + jpeg_local_only(); }
EOF
# A member a later libjpeg might add: it defines a name the header (made from the first build) lacks.
cat >"$S/jextra.c" <<'EOF'
int jpeg_new_api(void) { return 5; }
EOF
# Toy qpdf: C++ calling the C library, the way Pl_DCT.cc does through jpeglib.h.
cat >"$S/Pl_DCT.cc" <<'EOF'
extern "C" {
extern const int jpeg_natural_order[];
int jpeg_std_error(void);
int qpdf_init(void);
}
int qpdf_init(void) { return jpeg_natural_order[2] * 10 + jpeg_std_error(); }
EOF
# Toy PDFium: functions mangled, the table not, and the table a private external, as in libpdfium.a.
cat >"$S/jutils-pdfium.c" <<'EOF'
__attribute__((visibility("hidden"))) const int jpeg_natural_order[4] = { 7, 7, 7, 7 };
int chromium_jpeg_std_error(void) { return jpeg_natural_order[0]; }
EOF
cat >"$S/fpdf_view.c" <<'EOF'
int chromium_jpeg_std_error(void);
int FPDF_InitLibrary(void) { return chromium_jpeg_std_error(); }
EOF
cat >"$S/app.c" <<'EOF'
#include <stdio.h>
int FPDF_InitLibrary(void);
int qpdf_init(void);
int main(void) { printf("pdfium %d qpdf %d\n", FPDF_InitLibrary(), qpdf_init()); return 0; }
EOF

cc_obj() { # <out.o> <source> [extra flags...]
  local out="$1" src="$2"
  shift 2
  case "$src" in
    *.cc) "$CXX" -std=c++17 "${cflags[@]}" "$@" -c "$src" -o "$out" ;;
    *) "$CC" "${cflags[@]}" "$@" -c "$src" -o "$out" ;;
  esac
}
archive() { # <out.a> <objects...>
  local out="$1"
  shift
  rm -f "$out"
  xcrun libtool -static -arch_only arm64 -o "$out" "$@" 2>/dev/null
}
O="$WORK/obj"

# The toy PDFium and the app object, built once.
mkdir -p "$O/pdfium"
cc_obj "$O/pdfium/jutils.o" "$S/jutils-pdfium.c"
cc_obj "$O/pdfium/fpdf_view.o" "$S/fpdf_view.c"
archive "$WORK/libpdfium.a" "$O/pdfium/jutils.o" "$O/pdfium/fpdf_view.o"
cc_obj "$O/app.o" "$S/app.c"

# Pass 1, the plain build: libjpeg and qpdf without the header, merged the way qpdf-build.sh merges.
mkdir -p "$O/plain"
cc_obj "$O/plain/jutils.c.o" "$S/jutils.c"
cc_obj "$O/plain/jerror.c.o" "$S/jerror.c"
cc_obj "$O/plain/Pl_DCT.cc.o" "$S/Pl_DCT.cc"
archive "$WORK/libjpeg-plain.a" "$O/plain/jutils.c.o" "$O/plain/jerror.c.o"
archive "$WORK/libqpdfcore-plain.a" "$O/plain/Pl_DCT.cc.o"
archive "$WORK/libqpdf-plain.a" "$WORK/libqpdfcore-plain.a" "$WORK/libjpeg-plain.a"

# Shipped headers: one names a libjpeg type (fine, types are not symbols), one calls a libjpeg function.
mkdir -p "$WORK/headers-clean/qpdf" "$WORK/headers-bad/qpdf"
printf 'struct jpeg_compress_struct;\nvoid apply(jpeg_compress_struct*);\n' >"$WORK/headers-clean/qpdf/Pl_DCT.hh"
cp "$WORK/headers-clean/qpdf/Pl_DCT.hh" "$WORK/headers-bad/qpdf/Pl_DCT.hh"
printf 'extern "C" int jpeg_std_error(void);\ninline int qpdf_jpeg_hook() { return jpeg_std_error(); }\n' >"$WORK/headers-bad/qpdf/Inline.hh"

# --- RED on the plain build: the bug itself ---
set +e
link_out="$("$CXX" -arch arm64 -isysroot "$SDK" "$O/app.o" "$WORK/libpdfium.a" "$WORK/libqpdf-plain.a" -o "$WORK/app-plain" 2>&1)"; code=$?
set -e
check "the plain merge fails an app's link with a duplicate _jpeg_natural_order (the bug)" $([ "$code" -ne 0 ] && has "$link_out" "duplicate symbol '_jpeg_natural_order'"; echo $?)

# --- the header ---
set +e
out="$("$TOOL" header "$WORK/libjpeg-plain.a" "$WORK/qpdfjt-prefix.h" 2>&1)"; code=$?
set -e
check "header: exit 0 on the plain toy libjpeg" $([ "$code" -eq 0 ] && [ -s "$WORK/qpdfjt-prefix.h" ]; echo $?)
defines="$(grep -E '^#define [a-z]' "$WORK/qpdfjt-prefix.h" 2>/dev/null || true)"
want="#define jpeg_common_counter qpdfjt_jpeg_common_counter
#define jpeg_hidden_helper qpdfjt_jpeg_hidden_helper
#define jpeg_natural_order qpdfjt_jpeg_natural_order
#define jpeg_std_error qpdfjt_jpeg_std_error
#define jpeg_weak_hook qpdfjt_jpeg_weak_hook
#define jround_up qpdfjt_jround_up"
check "header: exactly one define per external, private external, weak and common definition" $([ "$defines" = "$want" ]; echo $?)
check "header: the static function is not listed" $(lacks "$(cat "$WORK/qpdfjt-prefix.h" 2>/dev/null)" "jpeg_local_only"; echo $?)
check "header: has an include guard" $(grep -qx '#ifndef QPDFJT_PREFIX_H' "$WORK/qpdfjt-prefix.h" 2>/dev/null && grep -qx '#endif' "$WORK/qpdfjt-prefix.h"; echo $?)

# Pass 2: rebuild libjpeg and compile qpdf with the header force-included, then merge.
H="$WORK/qpdfjt-prefix.h"
mkdir -p "$O/pre"
cc_obj "$O/pre/jutils.c.o" "$S/jutils.c" -include "$H"
cc_obj "$O/pre/jerror.c.o" "$S/jerror.c" -include "$H"
cc_obj "$O/pre/jextra.c.o" "$S/jextra.c" -include "$H"
cc_obj "$O/pre/Pl_DCT.cc.o" "$S/Pl_DCT.cc" -include "$H"
archive "$WORK/libjpeg.a" "$O/pre/jutils.c.o" "$O/pre/jerror.c.o"
archive "$WORK/libqpdfcore.a" "$O/pre/Pl_DCT.cc.o"
archive "$WORK/libqpdf.a" "$WORK/libqpdfcore.a" "$WORK/libjpeg.a"

# --- GREEN: the prefixed build ---
set +e
out="$("$TOOL" check "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean" 2>&1)"; code=$?
set -e
check "check: the prefixed archive passes (exit 0, success line)" $([ "$code" -eq 0 ] && has "$out" "qpdf-jpeg-prefix: ok (6 libjpeg names carry the qpdfjt_ prefix, 2 libjpeg members checked"; echo $?)
set +e
link_out="$("$CXX" -arch arm64 -isysroot "$SDK" "$O/app.o" "$WORK/libpdfium.a" "$WORK/libqpdf.a" -o "$WORK/app" 2>&1)"; code=$?
set -e
check "the prefixed archive links next to the toy PDFium" $([ "$code" -eq 0 ] && [ -x "$WORK/app" ]; echo $?)
run_out="$("$WORK/app" 2>&1 || true)"
check "each engine still reads its own table (pdfium 7, qpdf 81)" $([ "$run_out" = "pdfium 7 qpdf 81" ]; echo $?)

# --- RED: every half-right archive is refused ---
refused() { # <expected text> <check args...>: true when the check exits 1 and prints the text
  local want="$1" o c=0
  shift
  o="$("$TOOL" check "$@" 2>&1)" || c=$?
  [ "$c" -eq 1 ] && has "$o" "$want"
}
check "check: the plain merge is refused for its unprefixed definition" $(refused "jutils.c.o defines _jpeg_natural_order" "$WORK/libqpdf-plain.a" "$WORK/libjpeg-plain.a" "$H" "$WORK/headers-clean"; echo $?)
check "check: the plain merge is refused for the hidden helper too (private externs count)" $(refused "jutils.c.o defines _jpeg_hidden_helper" "$WORK/libqpdf-plain.a" "$WORK/libjpeg-plain.a" "$H" "$WORK/headers-clean"; echo $?)

archive "$WORK/libqpdf-plain-caller.a" "$WORK/libqpdfcore-plain.a" "$WORK/libjpeg.a"
check "check: qpdf compiled without the header is refused (unprefixed reference)" $(refused "Pl_DCT.cc.o references _jpeg_std_error" "$WORK/libqpdf-plain-caller.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean"; echo $?)

archive "$WORK/libqpdf-plain-jpeg.a" "$WORK/libqpdfcore.a" "$WORK/libjpeg-plain.a"
check "check: libjpeg rebuilt without the header is refused (prefixed names left undefined)" $(refused "_qpdfjt_jpeg_std_error is referenced but not defined" "$WORK/libqpdf-plain-jpeg.a" "$WORK/libjpeg-plain.a" "$H" "$WORK/headers-clean"; echo $?)
check "check: ...and names its unprefixed definitions" $(refused "jerror.c.o defines _jpeg_std_error" "$WORK/libqpdf-plain-jpeg.a" "$WORK/libjpeg-plain.a" "$H" "$WORK/headers-clean"; echo $?)

archive "$WORK/libjpeg-extra.a" "$O/pre/jutils.c.o" "$O/pre/jerror.c.o" "$O/pre/jextra.c.o"
archive "$WORK/libqpdf-extra.a" "$WORK/libqpdfcore.a" "$WORK/libjpeg-extra.a"
check "check: a libjpeg member with a name the header lacks is refused" $(refused "libjpeg member jextra.c.o defines _jpeg_new_api without the qpdfjt_ prefix" "$WORK/libqpdf-extra.a" "$WORK/libjpeg-extra.a" "$H" "$WORK/headers-clean"; echo $?)

cp "$H" "$WORK/prefix-gone.h"
printf '#define jpeg_gone qpdfjt_jpeg_gone\n' >>"$WORK/prefix-gone.h"
check "check: a listed name the rebuilt libjpeg does not define is refused" $(refused "_qpdfjt_jpeg_gone is not defined by any libjpeg member" "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$WORK/prefix-gone.h" "$WORK/headers-clean"; echo $?)

archive "$WORK/libqpdf-short.a" "$WORK/libqpdfcore.a" "$O/pre/jerror.c.o"
check "check: a libjpeg member missing from the merged archive is refused" $(refused "libjpeg member jutils.c.o is in libqpdf-short.a 0 times" "$WORK/libqpdf-short.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean"; echo $?)

check "check: a shipped header that uses a renamed name is refused" $(refused "Inline.hh" "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-bad"; echo $?)

printf '/* no defines */\n' >"$WORK/empty-prefix.h"
check "check: a header with no names is refused" $(refused "lists no name" "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$WORK/empty-prefix.h" "$WORK/headers-clean"; echo $?)

# --- header refusals ---
header_refused() { # <expected exit> <expected text> <archive>
  local want_code="$1" want="$2" o c=0
  o="$("$TOOL" header "$3" "$WORK/refused.h" 2>&1)" || c=$?
  [ "$c" -eq "$want_code" ] && has "$o" "$want" && [ ! -e "$WORK/refused.h" ]
}
check "header: an already prefixed archive is refused" $(header_refused 1 "already carry the qpdfjt_ prefix" "$WORK/libjpeg.a"; echo $?)
printf 'static int only_local(void) { return 1; }\nint call_it(void);\n' >"$S/locals.c"
cc_obj "$O/locals.c.o" "$S/locals.c"
archive "$WORK/liblocals.a" "$O/locals.c.o"
check "header: an archive with no external definition is refused" $(header_refused 1 "defines no external symbol" "$WORK/liblocals.a"; echo $?)
printf 'int odd_name(void) __asm__("jpeg_no_underscore");\nint odd_name(void) { return 1; }\n' >"$S/odd.c"
cc_obj "$O/odd.c.o" "$S/odd.c"
archive "$WORK/libodd.a" "$O/odd.c.o"
check "header: a name the preprocessor cannot rename is refused" $(header_refused 1 "jpeg_no_underscore" "$WORK/libodd.a"; echo $?)
check "header: a missing archive exits 2" $(header_refused 2 "not a file" "$WORK/nope.a"; echo $?)

# --- tool failures are never a pass ---
mkdir -p "$WORK/badnm" "$WORK/emptynm"
printf '#!/usr/bin/env bash\necho "nm: broken" >&2\nexit 1\n' >"$WORK/badnm/nm"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/emptynm/nm"
chmod +x "$WORK/badnm/nm" "$WORK/emptynm/nm"
set +e
out="$(PATH="$WORK/badnm:$PATH" "$TOOL" check "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean" 2>&1)"; code=$?
set -e
check "check: nm failing exits 2 and says so" $([ "$code" -eq 2 ] && has "$out" "nm failed"; echo $?)
set +e
out="$(PATH="$WORK/badnm:$PATH" "$TOOL" header "$WORK/libjpeg-plain.a" "$WORK/refused.h" 2>&1)"; code=$?
set -e
check "header: nm failing exits 2 and writes nothing" $([ "$code" -eq 2 ] && has "$out" "nm failed" && [ ! -e "$WORK/refused.h" ]; echo $?)
set +e
out="$(PATH="$WORK/emptynm:$PATH" "$TOOL" check "$WORK/libqpdf.a" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean" 2>&1)"; code=$?
set -e
check "check: nm printing nothing is refused (its members must match ar's)" $([ "$code" -eq 1 ] && has "$out" "members"; echo $?)
set +e
out="$("$TOOL" check "$S/app.c" "$WORK/libjpeg.a" "$H" "$WORK/headers-clean" 2>&1)"; code=$?
set -e
check "check: a file that is not an archive exits 2" $([ "$code" -eq 2 ]; echo $?)
set +e
out="$("$TOOL" check "$WORK/libqpdf.a" 2>&1)"; code=$?
set -e
check "check: missing arguments exit 2 with usage" $([ "$code" -eq 2 ] && has "$out" "usage"; echo $?)
set +e
out="$("$TOOL" bogus 2>&1)"; code=$?
set -e
check "an unknown subcommand exits 2" $([ "$code" -eq 2 ]; echo $?)

# --- scripts/qpdf-build.sh end to end: toy sources and a fake cmake ---
# The fake cmake configures by recording the flags qpdf-build.sh passes, builds by compiling the toy sources
# with CMAKE_C_FLAGS and CMAKE_CXX_FLAGS (as CMake would), and installs the archive and headers. This runs
# the real, non-dry script: the header is made from pass 1, reaches the pass 2 and qpdf compiles, and the
# check after the merge stops the build (exit 6) when either compile goes without it.
# shellcheck source=../../versions.env
. "$REPO/versions.env"
E="$WORK/e2e"
JSRC="$E/work/src/libjpeg-turbo-$LIBJPEG_TURBO_VERSION"
QSRC="$E/work/src/qpdf-$QPDF_VERSION"
mkdir -p "$JSRC" "$QSRC/include/qpdf" "$E/bin"
cp "$S/jutils.c" "$S/jerror.c" "$JSRC/"
printf '/* toy jpeglib.h */\n' >"$JSRC/jpeglib.h"
cp "$S/Pl_DCT.cc" "$QSRC/"
printf 'extern "C" int QPDFCrypto_native_toy(void) { return 1; }\n' >"$QSRC/QPDFCrypto_native.cc"
printf '#define USE_CRYPTO_NATIVE 1\n#define DEFAULT_CRYPTO "native"\n' >"$QSRC/qpdf-config.h"
printf '/* toy */\n' >"$QSRC/include/qpdf/Types.h"
cp "$WORK/headers-clean/qpdf/Pl_DCT.hh" "$QSRC/include/qpdf/"
printf '#!/usr/bin/env bash\necho "fake gh: no download expected" >&2\nexit 1\n' >"$E/bin/gh"
cat >"$E/bin/cmake" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  -S)
    src="$2"
    shift 2
    bdir="" prefix="" cflags="" cxxflags="" deploy=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -B) bdir="$2"; shift 2 ;;
        -DCMAKE_INSTALL_PREFIX=*) prefix="${1#*=}"; shift ;;
        -DCMAKE_C_FLAGS=*) cflags="${1#*=}"; shift ;;
        -DCMAKE_CXX_FLAGS=*) cxxflags="${1#*=}"; shift ;;
        -DCMAKE_OSX_DEPLOYMENT_TARGET=*) deploy="${1#*=}"; shift ;;
        *) shift ;;
      esac
    done
    case "$(basename "$src")" in qpdf-*) kind=qpdf ;; *) kind=jpeg ;; esac
    if [ "${FAKE_DROP_FLAGS:-}" = "$kind" ]; then cflags="" cxxflags=""; fi
    mkdir -p "$bdir"
    printf 'src=%q\nprefix=%q\ncflags=%q\ncxxflags=%q\ndeploy=%q\nkind=%q\n' \
      "$src" "$prefix" "$cflags" "$cxxflags" "$deploy" "$kind" >"$bdir/fake.env"
    if [ "$kind" = qpdf ]; then mkdir -p "$bdir/libqpdf/qpdf"; cp "$src/qpdf-config.h" "$bdir/libqpdf/qpdf/"; fi
    ;;
  --build)
    bdir="$2"
    . "$bdir/fake.env"
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    objs=()
    for f in "$src"/*.c "$src"/*.cc; do
      [ -f "$f" ] || continue
      o="$bdir/$(basename "$f").o"
      case "$f" in
        *.cc) xcrun clang++ -std=c++17 -arch arm64 -isysroot "$sdk" -mmacosx-version-min="$deploy" $cxxflags -c "$f" -o "$o" ;;
        *) xcrun clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min="$deploy" $cflags -c "$f" -o "$o" ;;
      esac
      objs+=("$o")
    done
    if [ "$kind" = qpdf ]; then out="$bdir/libqpdf/libqpdf.a"; else out="$bdir/libjpeg.a"; fi
    xcrun libtool -static -arch_only arm64 -o "$out" "${objs[@]}" 2>/dev/null
    ;;
  --install)
    bdir="$2"
    . "$bdir/fake.env"
    mkdir -p "$prefix/lib" "$prefix/include"
    cp "$bdir/libjpeg.a" "$prefix/lib/libjpeg.a"
    cp "$src"/*.h "$prefix/include/"
    ;;
  *) echo "fake cmake: unexpected arguments: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$E/bin/gh" "$E/bin/cmake"
e2e() { # [VAR=value...]: runs qpdf-build.sh macos-arm64 with the fake cmake; prints its output
  env PATH="$E/bin:$PATH" WORK_DIR="$E/work" OUT_DIR="$E/out" "$@" "$REPO/scripts/qpdf-build.sh" macos-arm64 2>&1
}
set +e
out="$(e2e)"; code=$?
set -e
check "build: the real script with toy sources succeeds (exit 0)" $([ "$code" -eq 0 ]; echo $?)
check "build: the header is made from pass 1 (all 6 toy names)" $(has "$out" "qpdf-jpeg-prefix.sh: wrote 6 names to $E/work/build/macos-arm64/qpdfjt-prefix.h"; echo $?)
check "build: the S11 guards still run and pass" $(has "$out" "qpdf-config-guard: ok (native crypto only)" && has "$out" "check-no-tls-symbols: ok"; echo $?)
check "build: the prefix check runs after the merge and passes" $(has "$out" "qpdf-jpeg-prefix: ok (6 libjpeg names carry the qpdfjt_ prefix, 2 libjpeg members checked, no unprefixed definition or reference in libqpdf.a, shipped headers clean)"; echo $?)
built="$E/out/qpdf/macos-arm64/libqpdf.a"
check "build: the shipped archive defines the prefixed table and not the plain one" $(nm -m "$built" >"$WORK/built.nm" 2>/dev/null && grep -q ' external _qpdfjt_jpeg_natural_order$' "$WORK/built.nm" && ! grep -q ' external _jpeg_natural_order$' "$WORK/built.nm"; echo $?)
set +e
out="$(e2e FAKE_DROP_FLAGS=qpdf)"; code=$?
set -e
check "build: qpdf compiled without the header stops the build (exit 6, names the reference)" $([ "$code" -eq 6 ] && has "$out" "Pl_DCT.cc.o references _jpeg_std_error" && has "$out" "not fully prefixed"; echo $?)
set +e
out="$(e2e FAKE_DROP_FLAGS=jpeg)"; code=$?
set -e
check "build: libjpeg rebuilt without the header stops the build (exit 6, names the definition)" $([ "$code" -eq 6 ] && has "$out" "defines _jpeg_natural_order"; echo $?)
set +e
out="$(e2e PATH="$WORK/badnm:$E/bin:$PATH")"; code=$?
set -e
check "build: a header that cannot be made stops the build (exit 6) before pass 2" $([ "$code" -eq 6 ] && has "$out" "could not make the libjpeg-turbo prefix header" && [ ! -e "$E/work/build/macos-arm64/jpeg" ]; echo $?)

if [ "$failures" -gt 0 ]; then
  echo "qpdf-jpeg-prefix-test: $failures failure(s)"
  exit 1
fi
echo "qpdf-jpeg-prefix-test: all passed"
