#!/usr/bin/env bash
# Runs summarize.sh against `needs` fixtures: the verdict is the required status
# context, so a red or cancelled job that reads as green, or a green one that
# reads as red, is a PR that merges broken or one that can never merge.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/summarize.sh"
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# run NEEDS IGNORE DOCS_ONLY: sets $STATUS and $OUT (stdout and stderr).
run() {
  OUT="$(NEEDS="$1" IGNORE="$2" DOCS_ONLY="${3:-false}" "$SCRIPT" 2>&1)"
  STATUS=$?
}
# expect NAME STATUS TEXT: the exit status, and that TEXT is in the output.
expect() {
  if [ "$STATUS" -ne "$2" ]; then bad "$1" "exit $STATUS, want $2: $OUT"
  elif ! grep -qF -- "$3" <<<"$OUT"; then bad "$1" "no '$3' in: $OUT"
  else ok "$1"; fi
}

GREEN='{"pick":{"result":"success"},"checks":{"result":"success"},"test":{"result":"success"},"build":{"result":"success"}}'
run "$GREEN" ""
expect "every job green passes" 0 "pr-checks: all required jobs passed"

run '{"pick":{"result":"success"},"checks":{"result":"skipped"},"test":{"result":"skipped"},"all":{"result":"success"}}' ""
expect "skipped jobs never fail the verdict" 0 "all required jobs passed"

run "$GREEN" "" true
expect "docs-only only changes the message" 0 "pr-checks: docs-only change, checks skipped"

run '{"pick":{"result":"success"},"checks":{"result":"failure"},"test":{"result":"success"}}' ""
expect "a failed job fails and is named" 1 "::error::pr-checks: failed jobs: checks(failure)"

run '{"pick":{"result":"success"},"build":{"result":"cancelled"}}' ""
expect "a cancelled job fails and is named" 1 "failed jobs: build(cancelled)"

run '{"pick":{"result":"failure"},"checks":{"result":"skipped"},"test":{"result":"cancelled"},"build":{"result":"failure"}}' ""
expect "every failure is listed, in the order given" 1 "failed jobs: pick(failure) test(cancelled) build(failure)"

run '{"checks":{"result":"failure"}}' "" true
expect "a failure fails on a docs-only change too" 1 "failed jobs: checks(failure)"

ADVISORY='{"pick":{"result":"success"},"zavet":{"result":"failure"},"react-doctor":{"result":"cancelled"}}'
run "$ADVISORY" "zavet react-doctor"
expect "advisory jobs are read as skipped" 0 "all required jobs passed"

run "$ADVISORY" "zavet "
expect "only the named advisory job is ignored" 1 "failed jobs: react-doctor(cancelled)"

run "$ADVISORY" "  zavet   react-doctor  "
expect "extra spaces in the ignore list change nothing" 0 "all required jobs passed"

run '{"checks":{"result":"failure"},"zavet":{"result":"failure"}}' "zavet"
expect "an advisory job never hides a required one" 1 "failed jobs: checks(failure)"

run '{"react-doctor":{"result":"failure"}}' "doctor react"
expect "an ignore entry is a whole job id, not a part of one" 1 "react-doctor(failure)"

# jq's own `inside` would match a substring here.
run '{"doctor":{"result":"failure"}}' "react-doctor"
expect "a job id inside an ignored id is not ignored" 1 "doctor(failure)"

run '{"zavet":{"result":"failure"}}' "zavet"
expect "a lone advisory failure passes" 0 "all required jobs passed"

run '{}' ""
expect "no jobs is no verdict" 1 "no jobs to summarize"

run '' ""
expect "an empty needs fails closed" 1 "no jobs to summarize"

run 'not json' ""
expect "unparsable needs fails closed" 1 "no jobs to summarize"

# The real context also carries outputs, some of them empty or with quotes.
run '{"pick":{"result":"success","outputs":{"key":"123","light":"[\"self-hosted\"]"}},"checks":{"result":"failure","outputs":{}}}' ""
expect "outputs in the context do not matter" 1 "failed jobs: checks(failure)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
