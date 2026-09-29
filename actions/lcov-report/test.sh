#!/usr/bin/env bash
# Assert the arithmetic and the floors against fixture LCOV files: an empty
# report, several files, absolute paths from another runner, and a file with no
# instrumented lines. A wrong percentage or a floor that never trips is quiet.
# The backticks in the expected text are markdown, not command substitution.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/lcov-report.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcov-report-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

: > "$WORK/empty.info"

cat > "$WORK/multi.info" <<'LCOV'
TN:
SF:src/a.ts
DA:1,1
LF:10
LH:9
end_of_record
SF:src/b.ts
LF:10
LH:5
end_of_record
SF:src/c.ts
LF:80
LH:66
end_of_record
LCOV

# Written on another runner, so its workspace is not ours. `./` and CRLF too.
printf 'SF:/runner/work/r/r/src/a.ts\r\nLF:10\r\nLH:9\r\nend_of_record\r\nSF:./src/b.ts\nLF:10\nLH:5\nend_of_record\nSF:/elsewhere/lib.ts\nLF:4\nLH:4\nend_of_record\n' > "$WORK/abs.info"

# A file with nothing to instrument beside one that has lines.
printf 'SF:src/types.ts\nLF:0\nLH:0\nend_of_record\nSF:src/a.ts\nLF:10\nLH:8\nend_of_record\n' > "$WORK/zero.info"

# $1 name, $2 lcov file, $3 changed files, $4 min overall, $5 min changed, $6 root
# Sets $OUTS (the outputs) and $MD (the comment) for the assertions.
run() {
  OUTS="$WORK/out"; MD="$WORK/report.md"
  : > "$OUTS"; rm -f "$MD"
  LCOV_FILE="$2" CHANGED_FILES="$3" MIN_OVERALL="$4" MIN_CHANGED="$5" ROOT="${6:-}" \
    OUT="$MD" GITHUB_OUTPUT="$OUTS" "$SCRIPT" > "$WORK/log" 2>&1
}
out() { grep "^$1=" "$OUTS" | head -1 | cut -d= -f2-; }
expect() { # name, key, want
  local got; got="$(out "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "$2 is '$got', wanted '$3'"; fi
}
expect_md() { # name, text the comment must hold
  if grep -qF -- "$2" "$MD"; then ok "$1"; else bad "$1" "comment lacks: $2"; fi
}

# 80 of 100 lines overall: (9 + 5 + 66) / (10 + 10 + 80).
run x "$WORK/multi.info" "" 0 0
expect "overall is sum of LH over sum of LF"  overall 80.0
expect "no changed list, no changed figure"   changed ""
expect "no floor, no failure"                 failed ""
expect_md "the comment says the list is missing" "not listed"

run x "$WORK/multi.info" $'src/a.ts\nsrc/b.ts\ndocs/readme.md' 0 0
expect "changed files pool their lines"       changed 70.0
expect_md "the comment counts files in the report" "2 of 3 in the report"
expect_md "the worst changed file comes first" '| `src/b.ts` | 5 / 10 | 50.0% |'

run x "$WORK/multi.info" "" 80 0
expect "a floor equal to the figure passes"   failed ""
run x "$WORK/multi.info" "" 80.1 0
expect "a floor just above the figure fails"  failed "overall coverage 80.0% is below the 80.1% minimum"
expect_md "the comment says why it failed"    "Below the minimum"

run x "$WORK/multi.info" $'src/a.ts\nsrc/b.ts' 0 75
expect "the changed floor fails on its own"   failed "changed-file coverage 70.0% is below the 75% minimum"

# Sorted worst first, and no more than five listed.
many=""; for i in 1 2 3 4 5 6 7; do many="${many}SF:f$i.ts"$'\n'"LF:10"$'\n'"LH:$i"$'\nend_of_record\n'; done
printf '%s' "$many" > "$WORK/many.info"
run x "$WORK/many.info" $'f1.ts\nf2.ts\nf3.ts\nf4.ts\nf5.ts\nf6.ts\nf7.ts' 0 0
expect_md "the lowest file is listed"   '`f1.ts`'
expect_md "the fifth lowest is listed"  '`f5.ts`'
if grep -qF '`f6.ts`' "$MD"; then bad "only five files are listed" "f6.ts is there"; else ok "only five files are listed"; fi

run x "$WORK/empty.info" "" 0 0
expect "an empty report has no overall figure" overall ""
run x "$WORK/empty.info" "" 50 0
expect "an empty report fails a floor"         failed "the report has no instrumented lines, so overall coverage cannot meet the 50% minimum"

# The root is the test runner's workspace, never this job's.
run x "$WORK/abs.info" $'src/a.ts\nsrc/b.ts' 0 0 /runner/work/r/r/
expect "absolute and ./ paths match, trailing slash or not" changed 70.0
run x "$WORK/abs.info" $'lib.ts' 0 0 /runner/work/r/r
expect "a path outside the root stays absolute"        changed ""

# LF=0 has no lines to measure: it is not 0%, and it does not divide by zero.
run x "$WORK/zero.info" $'src/types.ts\nsrc/a.ts' 0 90
expect "a file with no lines is left out"      changed 80.0
expect "so a floor is judged on the rest"      failed "changed-file coverage 80.0% is below the 90% minimum"
run x "$WORK/zero.info" $'src/types.ts' 0 90
expect "only a no-line file changed: no figure" changed ""
expect "and no changed floor to fail"           failed ""

# A file name from the report must not break the table.
printf 'SF:src/we|ird`.ts\nLF:2\nLH:1\nend_of_record\n' > "$WORK/odd.info"
run x "$WORK/odd.info" 'src/we|ird`.ts' 0 0
expect_md "pipes and backticks are stripped from names" '| `src/weird.ts` | 1 / 2 | 50.0% |'

# The path may be a glob, for the one file in a download directory.
mkdir "$WORK/dl"; cp "$WORK/multi.info" "$WORK/dl/whatever.info"
run x "$WORK/dl/*" "" 0 0
expect "a glob finds the report" overall 80.0

# A missing file is an error, not a pass.
if OUT="$WORK/m.md" LCOV_FILE="$WORK/nope.info" GITHUB_OUTPUT="$WORK/o" "$SCRIPT" >/dev/null 2>&1; then
  bad "a missing report fails" "exited 0"
else ok "a missing report fails"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
