#!/usr/bin/env bash
# Usage: scripts/qpdf-jpeg-prefix.sh header <libjpeg.a> <out.h>
#        scripts/qpdf-jpeg-prefix.sh check <libqpdf.a> <libjpeg.a> <prefix.h> <shipped headers dir>
#
# Gives qpdf's copy of libjpeg-turbo its own names. PDFium carries Chromium's libjpeg_turbo, which renames
# its functions (chromium_jpeg_*) but not every table: in CI run 39083399705 libpdfium.a (private external)
# and libqpdf.a (external) both defined _jpeg_natural_order, the release gate refused, and an app linking
# both engines failed with "duplicate symbol '_jpeg_natural_order'". So EVERY external name of qpdf's copy
# gets the prefix qpdfjt_, not only the one that collides today. scripts/qpdf-build.sh builds libjpeg-turbo
# once as is, runs `header` on that archive, rebuilds libjpeg-turbo and builds qpdf with the header
# force-included (-include), merges the two, and runs `check` on the merged archive.
#
# header: writes one "#define <name> qpdfjt_<name>" line for every symbol the archive defines as external or
#   private external (weak and common definitions too; private externs are global within a static link),
#   with Mach-O's leading underscore stripped. Refuses (exit 1, nothing written) when the archive defines no
#   external symbol, when a name is not an underscore plus a C identifier (the preprocessor cannot rename
#   it), or when a name already carries the prefix (the archive is the rebuilt one, not the plain one).
# check: refuses (exit 1) unless all of these hold:
#   1. nm names exactly the members ar lists, so a change in nm's output cannot hide a member; every member
#      of <libjpeg.a> is in the merged archive exactly once;
#   2. no member defines a name from the header without the prefix;
#   3. no member references a name from the header without the prefix;
#   4. every external definition in a libjpeg member carries the prefix (this catches a name the header
#      lacks);
#   5. every name in the header is defined, prefixed, by a libjpeg member, and every prefixed name any
#      member references is defined in the archive;
#   6. no header in <shipped headers dir> uses a name from the header: an app compiles those headers
#      without the prefix header, so such a use would not match the library.
#   It prints every problem it finds before it refuses, and one "qpdf-jpeg-prefix: ok (...)" line on success.
#
# Exit codes: 0 ok, 1 refused, 2 usage, missing input, or nm or ar failed.
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

JPEG_PREFIX=qpdfjt_
USAGE="usage: qpdf-jpeg-prefix.sh header <libjpeg.a> <out.h> | check <libqpdf.a> <libjpeg.a> <prefix.h> <shipped headers dir>"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/qpdf-jpeg-prefix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# symbols <archive> <out>: reads `nm -m <archive>` and writes
#   <out>          one line per global symbol: "D" (defined: external or private external, weak and
#                  common included) or "U" (undefined), the member, the Mach-O name; tab separated
#   <out>.members  every member nm names, one per line
# nm runs on its own, never in a pipe, so its failure stops the script.
symbols() {
  local lib="$1" out="$2"
  [ -f "$lib" ] || die 2 "not a file: $lib"
  nm -m "$lib" >"$out.nm" 2>"$out.err" || die 2 "nm failed on $lib: $(head -1 "$out.err")"
  : >"$out"
  : >"$out.members"
  # A member header is "name.o:" (or "lib.a(name.o):"); a symbol line starts with an address or with
  # blanks. A symbol line before any member header means the output is not what this parser expects.
  awk -v tsv="$out" -v members="$out.members" '
    $0 == "" { next }
    /:$/ && !/^ / && !/^[0-9a-f]+ \(/ {
      m = substr($0, 1, length($0) - 1)
      if (m ~ /\)$/ && index(m, "(") > 0) { sub(/^[^(]*\(/, "", m); sub(/\)$/, "", m) }
      print m > members
      next
    }
    m == "" { bad = 1; exit }
    / \(undefined\) / { print "U\t" m "\t" $NF > tsv; next }
    / (private )?external / { print "D\t" m "\t" $NF > tsv; next }
    END { if (bad) exit 3 }
  ' "$out.nm" || die 2 "could not read the nm output for $lib (a symbol line before any member)"
}

# members <archive> <out>: the archive's members as ar lists them (symbol table left out), sorted.
members() {
  ar -t "$1" >"$2.raw" 2>"$2.err" || die 2 "ar failed on $1: $(head -1 "$2.err")"
  { grep -v '^__\.SYMDEF' "$2.raw" || true; } | LC_ALL=C sort >"$2"
}

# first <n>: the first n lines of stdin, indented; reads all of stdin (no SIGPIPE under pipefail).
first() { awk -v n="$1" 'NR <= n { print "  " $0 } END { if (NR > n) print "  ... and " NR - n " more" }'; }

cmd_header() {
  [ "$#" -eq 2 ] || die 2 "$USAGE"
  local lib="$1" out="$2" bad count
  symbols "$lib" "$TMP/jpeg"
  awk -F '\t' '$1 == "D" { print $3 }' "$TMP/jpeg" | LC_ALL=C sort -u >"$TMP/defs"
  [ -s "$TMP/defs" ] || die 1 "$(basename "$lib") defines no external symbol; refusing to write an empty prefix header"
  bad="$(grep -v -E '^_[A-Za-z_][A-Za-z0-9_]*$' "$TMP/defs" || true)"
  [ -z "$bad" ] || die 1 "$(basename "$lib") defines names the preprocessor cannot rename (not an underscore plus a C identifier):
$(printf '%s\n' "$bad" | first 5)"
  bad="$(grep -E "^_$JPEG_PREFIX" "$TMP/defs" || true)"
  [ -z "$bad" ] || die 1 "$(basename "$lib") defines names that already carry the $JPEG_PREFIX prefix; give header the plain libjpeg-turbo build:
$(printf '%s\n' "$bad" | first 5)"
  count="$(wc -l <"$TMP/defs" | tr -d ' ')"
  {
    echo "/* Generated by scripts/qpdf-jpeg-prefix.sh from $(basename "$lib"); do not edit."
    echo "   Every external name of qpdf's libjpeg-turbo copy ($count) gets the $JPEG_PREFIX prefix, so it cannot"
    echo "   collide with the libjpeg inside PDFium or an app. Force-included (-include) when libjpeg-turbo"
    echo "   and qpdf are compiled. */"
    echo "#ifndef QPDFJT_PREFIX_H"
    echo "#define QPDFJT_PREFIX_H"
    sed 's/^_//' "$TMP/defs" | awk -v p="$JPEG_PREFIX" '{ print "#define " $0 " " p $0 }'
    echo "#endif"
  } >"$TMP/header.h"
  mv "$TMP/header.h" "$out"
  log "wrote $count names to $out"
}

cmd_check() {
  [ "$#" -eq 4 ] || die 2 "$USAGE"
  local lib="$1" jpeg="$2" header="$3" shipped="$4" name status=0 found st
  name="$(basename "$lib")"
  [ -f "$header" ] || die 2 "prefix header not found: $header"
  [ -d "$shipped" ] || die 2 "shipped headers directory not found: $shipped"

  # The names the header renames: lines "#define X qpdfjt_X" only.
  sed -n -E "s/^#define ([A-Za-z_][A-Za-z0-9_]*) $JPEG_PREFIX([A-Za-z_][A-Za-z0-9_]*)\$/\\1 \\2/p" "$header" \
    | awk '$1 == $2 { print $1 }' | LC_ALL=C sort -u >"$TMP/names"
  [ -s "$TMP/names" ] || die 1 "$header lists no name to prefix; refusing to call the check passed"

  members "$lib" "$TMP/lib.ar"
  members "$jpeg" "$TMP/jpeg.ar"
  [ -s "$TMP/jpeg.ar" ] || die 1 "$(basename "$jpeg") has no member; refusing to call the check passed"
  found="$(uniq -d "$TMP/jpeg.ar")"
  [ -z "$found" ] || die 1 "$(basename "$jpeg") has members with the same name, so they cannot be told apart: $found"
  symbols "$lib" "$TMP/lib"
  LC_ALL=C sort "$TMP/lib.members" >"$TMP/lib.nm-members"
  if ! cmp -s "$TMP/lib.ar" "$TMP/lib.nm-members"; then
    die 1 "nm names $(wc -l <"$TMP/lib.nm-members" | tr -d ' ') members of $name but ar lists $(wc -l <"$TMP/lib.ar" | tr -d ' '); refusing to trust the symbol check"
  fi

  report() { # <title> <file>: prints the title and the file's first lines, and marks the check failed
    if [ -s "$2" ]; then
      printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
      first 10 <"$2" >&2
      status=1
    fi
  }

  # 1. every libjpeg member is in the merged archive exactly once
  awk -v lib="$name" 'NR == FNR { n[$0]++; next }
    n[$0] != 1 { print "libjpeg member " $0 " is in " lib " " (n[$0] + 0) " times (want exactly once)" }' \
    "$TMP/lib.ar" "$TMP/jpeg.ar" >"$TMP/p1"
  report "libjpeg members missing or repeated" "$TMP/p1"

  # 2. and 3. no unprefixed libjpeg name, defined or referenced
  awk -F '\t' 'NR == FNR { n["_" $0] = 1; next }
    ($3 in n) && $1 == "D" { print $2 " defines " $3 " (a libjpeg name without the prefix)" }' \
    "$TMP/names" "$TMP/lib" >"$TMP/p2"
  report "unprefixed libjpeg definitions in $name" "$TMP/p2"
  awk -F '\t' 'NR == FNR { n["_" $0] = 1; next }
    ($3 in n) && $1 == "U" { print $2 " references " $3 " (a libjpeg name without the prefix)" }' \
    "$TMP/names" "$TMP/lib" >"$TMP/p3"
  report "unprefixed libjpeg references in $name" "$TMP/p3"

  # 4. every external definition in a libjpeg member carries the prefix
  awk -F '\t' -v p="_$JPEG_PREFIX" -v pre="$JPEG_PREFIX" 'NR == FNR { j[$0] = 1; next }
    $1 == "D" && ($2 in j) && index($3, p) != 1 { print "libjpeg member " $2 " defines " $3 " without the " pre " prefix" }' \
    "$TMP/jpeg.ar" "$TMP/lib" >"$TMP/p4"
  report "libjpeg definitions without the prefix" "$TMP/p4"

  # 5. every listed name is defined, prefixed, by a libjpeg member; every prefixed reference resolves
  awk -F '\t' 'NR == FNR { j[$0] = 1; next } $1 == "D" && ($2 in j) { print $3 }' "$TMP/jpeg.ar" "$TMP/lib" \
    | LC_ALL=C sort -u >"$TMP/jpeg-defs"
  awk -F '\t' '$1 == "D" { print $3 }' "$TMP/lib" | LC_ALL=C sort -u >"$TMP/all-defs"
  awk -v p="_$JPEG_PREFIX" '{ print p $0 }' "$TMP/names" | LC_ALL=C sort -u >"$TMP/want-defs"
  LC_ALL=C comm -23 "$TMP/want-defs" "$TMP/jpeg-defs" | awk '{ print $0 " is not defined by any libjpeg member" }' >"$TMP/p5"
  report "prefixed names missing" "$TMP/p5"
  awk -F '\t' -v p="_$JPEG_PREFIX" 'NR == FNR { d[$0] = 1; next }
    $1 == "U" && index($3, p) == 1 && !($3 in d) { print $3 " is referenced but not defined in the archive (by " $2 ")" }' \
    "$TMP/all-defs" "$TMP/lib" >"$TMP/p6"
  report "prefixed references that do not resolve" "$TMP/p6"

  # 6. the shipped headers use no renamed name
  st=0
  grep -r -n -w -F -f "$TMP/names" "$shipped" >"$TMP/p7" || st=$?
  [ "$st" -le 1 ] || die 2 "grep failed on $shipped"
  report "shipped headers use libjpeg names (an app compiles them without the prefix header)" "$TMP/p7"

  if [ "$status" -ne 0 ]; then
    die 1 "REFUSED: the libjpeg-turbo copy in $name is not fully prefixed with $JPEG_PREFIX (see above); an app linking it next to PDFium could hit duplicate or crossed jpeg symbols"
  fi
  echo "qpdf-jpeg-prefix: ok ($(wc -l <"$TMP/names" | tr -d ' ') libjpeg names carry the $JPEG_PREFIX prefix, $(wc -l <"$TMP/jpeg.ar" | tr -d ' ') libjpeg members checked, no unprefixed definition or reference in $name, shipped headers clean)"
}

[ "$#" -ge 1 ] || die 2 "$USAGE"
sub="$1"
shift
case "$sub" in
  header) cmd_header "$@" ;;
  check) cmd_check "$@" ;;
  *) die 2 "$USAGE" ;;
esac
