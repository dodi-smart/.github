#!/usr/bin/env bash
# Runs floor.sh against figures around the floor: kover-report never fails on
# its own, so a floor that never trips, or one that trips on its boundary, is
# either a coverage collapse that merges or a pull request that can never.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/floor.sh"
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# run OVERALL MIN_OVERALL: sets $STATUS and $OUT (stdout and stderr).
run() {
  OUT="$(OVERALL="$1" MIN_OVERALL="$2" "$SCRIPT" 2>&1)"
  STATUS=$?
}
# expect NAME STATUS TEXT: the exit status, and that TEXT is in the output.
expect() {
  if [ "$STATUS" -ne "$2" ]; then bad "$1" "exit $STATUS, want $2: $OUT"
  elif ! grep -qF -- "$3" <<<"$OUT"; then bad "$1" "no '$3' in: $OUT"
  else ok "$1"; fi
}

run 0 40
expect "0% under a floor of 40 fails" 1 "::error::coverage: overall 0% is below the 40% floor"

run 39.99 40
expect "39.99 under a floor of 40 fails" 1 "overall 39.99% is below the 40% floor"

run 40 40
expect "exactly the floor passes" 0 "coverage: overall 40% (floor 40%)"

run 40.0 40
expect "40.0 against 40 passes" 0 "overall 40.0% (floor 40%)"

run 87.3 40
expect "above the floor passes" 0 "overall 87.3% (floor 40%)"

run 39.9 39.95
expect "a decimal floor compares as a number" 1 "below the 39.95% floor"

run 0 0
expect "a floor of 0 is off, even for 0%" 0 "overall 0% (floor 0%)"

run 12 ""
expect "an empty floor is off" 0 "overall 12% (floor 0%)"

run "" 40
expect "no figure fails" 1 "::error::coverage: kover-report produced no overall figure"

run "" 0
expect "no figure fails with no floor too" 1 "produced no overall figure"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
