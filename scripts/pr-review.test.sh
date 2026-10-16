#!/usr/bin/env bash
# Assert pr-review's decide step: the verdict other workflows merge on fails
# closed. The step is lifted out of the workflow and run on fixture files.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

python3 - "$ROOT" "$WORK" <<'EOF' || { echo 'cannot read the pr-review steps'; exit 1; }
import sys, yaml
root, work = sys.argv[1:3]
steps = yaml.safe_load(open(root + '/.github/workflows/pr-review.yml'))['jobs']['review']['steps']
open(work + '/decide.sh', 'w').write([s for s in steps if s.get('id') == 'decide'][0]['run'])
EOF
# decide RAW-JSON: what run-agent left in the report file. WHY stands in for
# run-agent's `why` output.
decide() {
  : > "$WORK/out"; rm -rf "$WORK/rv"
  printf '%s' "$1" > "$WORK/raw.json"
  ( env -i PATH="$PATH" RAW="$WORK/raw.json" OUT="$WORK/rv/review-verdict.json" SHA=abc MODE=scoped WHY="${WHY:-}" \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/decide.sh" ) > "$WORK/log" 2>&1
}
field() { jq -r "$1" "$WORK/rv/review-verdict.json"; }

decide '{"verdict":"approve","blocking":[]}'
expect "a clean approve is approve"                    test "$(field .verdict)" = approve
expect "and the status says so"                        grep -qx 'description=Approved' "$WORK/out"
expect "the file names the commit and the mode"        test "$(field '.sha + " " + .mode')" = 'abc scoped'
decide '{"verdict":"approve","blocking":[{"path":"a.ts","line":3,"summary":"x"}]}'
expect "approve with a blocking finding is changes"    test "$(field .verdict)" = changes
decide '{"verdict":"changes","blocking":[{"path":"a.ts","line":3,"summary":"x"},{"path":"b.ts"}]}'
expect "changes counts its blocking findings"          grep -qx 'description=Changes requested: 2 blocking' "$WORK/out"
expect "and fills missing fields"                      test "$(field '.blocking[1].line')" = 0
decide '{"verdict":"changes","blocking":[],"why":"The agent reached its turn cap after 40 turns."}'
expect "run-agent's fallback is changes"               test "$(field .verdict)" = changes
expect "with its why as the one blocking entry"        test "$(field '.blocking[0].summary')" = 'The agent reached its turn cap after 40 turns.'
decide 'not json'
expect "an unreadable file is changes"                 test "$(field .verdict)" = changes
decide '{"verdict":"lgtm","blocking":[]}'
expect "an unknown verdict word is changes"            test "$(field .verdict)" = changes
decide '{"verdict":"approve","blocking":"none"}'
expect "a blocking list that is not a list is changes" test "$(field .verdict)" = changes

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
