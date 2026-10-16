#!/usr/bin/env bash
# Assert which pull request facts.sh resolves, and every case it refuses. `gh`
# is a stub answering from the STUB_* variables.
# The stub's body is single-quoted on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-facts-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$WORK/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$STUB_CALLS"' 'case "$*" in' \
  '  *"/pulls?state=open"*) echo "${STUB_BRANCH_PR:-}" ;;' \
  '  *"/commits/"*"/pulls"*) echo "${STUB_STATUS_PR:-}" ;;' \
  '  *"/pulls/"*) jq -n --arg s "${STUB_STATE:-open}" --arg r "${STUB_HEAD_REPO:-o/r}" --arg h "${STUB_HEAD:-abc}" \
       '"'"'{number: 7, state: $s, draft: false, title: "chore(deps): x\nmore", user: {login: "renovate[bot]"},
         head: {sha: $h, ref: "renovate/x", repo: {full_name: $r}}, base: {ref: "develop"}, labels: [{name: "deps:minor"}]}'"'"' ;;' \
  'esac' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"

# facts EVENT PAYLOAD [VAR=VALUE...]: runs facts.sh; outputs land in $WORK/out.
facts() {
  local event="$1" payload="$2"; shift 2
  : > "$WORK/out"; : > "$WORK/calls"; printf '%s' "$payload" > "$WORK/event.json"
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" REPO=o/r EVENT="$event" \
    GITHUB_EVENT_PATH="$WORK/event.json" GITHUB_OUTPUT="$WORK/out" "$@" "$HERE/facts.sh" > /dev/null 2>&1
}
got() { sed -n "s/^$1=//p" "$WORK/out"; }

facts pull_request '{"pull_request":{"number":7}}'
expect "a pull_request event resolves its PR"           test "$(got found)" = true
expect "and reads its fields"                           test "$(got head-sha) $(got base-ref) $(got author)" = 'abc develop renovate[bot]'
expect "the title is one line"                          test "$(got title)" = 'chore(deps): x more'
expect "the labels are a JSON array"                    test "$(got labels)" = '["deps:minor"]'

facts workflow_run '{"workflow_run":{"event":"pull_request","head_sha":"abc","pull_requests":[{"number":7}]}}'
expect "a workflow_run names its PR"                    test "$(got found)" = true
facts workflow_run '{"workflow_run":{"event":"pull_request","head_sha":"old","pull_requests":[{"number":7}]}}'
expect "a workflow_run for an older head is refused"    test "$(got found)" = false
expect "and says it moved"                              grep -q 'has moved from old to abc' <(got why)
facts workflow_run '{"workflow_run":{"event":"push","head_sha":"abc"}}'
expect "a workflow_run for a push names no PR"          test "$(got found)" = false
facts workflow_run '{"workflow_run":{"event":"pull_request","head_sha":"abc","head_branch":"renovate/x","pull_requests":[]}}' STUB_BRANCH_PR=7
expect "a workflow_run without a PR falls back to the branch" test "$(got number)" = 7

facts status '{"sha":"abc"}' STUB_STATUS_PR=7
expect "a status resolves the open PR at that head"     test "$(got number)" = 7
facts status '{"sha":"abc"}'
expect "a status on a commit no open PR heads is refused" test "$(got found)" = false

facts pull_request '{"pull_request":{"number":7}}' STUB_STATE=closed
expect "a closed PR is refused"                         grep -qx 'why=#7 is closed' "$WORK/out"
facts pull_request '{"pull_request":{"number":7}}' STUB_HEAD_REPO=fork/r
expect "a fork is refused"                              grep -qx 'why=#7 comes from a fork' "$WORK/out"
facts '' '{}' NUMBER=7 EXPECTED_SHA=abc
expect "a number and the head it acted on: still the same PR" test "$(got found)" = true
facts '' '{}' NUMBER=7 EXPECTED_SHA=xyz
expect "a number whose head moved is refused"           test "$(got found)" = false
facts schedule '{}'
expect "an event with no PR is refused"                 test "$(got found)" = false

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
