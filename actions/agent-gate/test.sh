#!/usr/bin/env bash
# Regression tests for the agent gate.
#
# The gate is the org's security boundary: `agent:no-touch` stops every agent
# workflow, and DODI-00008 says it is evaluated FIRST with no exemption. That is
# a claim about behaviour, so it gets asserted rather than reviewed. The first
# block below is the one that matters — if any row in it proceeds, the kill
# switch is broken and the fix is not "adjust the test".
#
# Run: actions/agent-gate/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR and uses _CS_DARWIN_USER_TEMP_DIR. This org runs macOS
# runners, so that difference is not hypothetical.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
case_() {
  local want="$1" desc="$2"
  export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
  LABELS="$3" EVENT="$4" ACTION="$5" LABEL="$6" REQUEST="$7" AUTHOR="$8" DRAFT="$9" \
  COMMENT="${10}" COMMANDS="${11}" BOTS="${12}" SKIPDRAFT="${13}" FILES="${14}" \
    bash "$HERE/gate.sh" >"$TMP/log" 2>&1
  local got reason mark
  got=$(grep '^proceed=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)
  reason=$(grep '^reason=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-)
  if [ "$got" = "$want" ]; then mark="ok  "; pass=$((pass+1))
  else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %s %-46s proceed=%-6s %s\n' "$mark" "$desc" "$got" "$reason"
}

echo "== kill switch: agent:no-touch beats everything (DODI-00008) =="
case_ false "no-touch + labeled agent:triage"   '["agent:no-touch","agent:triage"]' issues labeled agent:triage agent:triage alice false '' 'triage plan' allow false ''
case_ false "no-touch + workflow_dispatch"      '["agent:no-touch"]' workflow_dispatch '' '' agent:triage alice false '' 'triage plan' allow false ''
case_ false "no-touch + @claude triage"         '["agent:no-touch"]' issue_comment created '' agent:triage alice false '@claude triage now' 'triage plan' allow false ''
case_ false "no-touch + PR ready_for_review"    '["agent:no-touch"]' pull_request ready_for_review '' agent:review alice false '' '' reject true 'src/a.ts'
case_ false "no-touch + renovate PR"            '["agent:no-touch"]' pull_request opened '' agent:review 'renovate[bot]' false '' '' only true ''

echo "== triage =="
case_ true  "labeled agent:triage"              '["agent:triage"]' issues labeled agent:triage agent:triage alice false '' 'triage plan' allow false ''
case_ false "labeled some other label"          '["bug"]' issues labeled bug agent:triage alice false '' 'triage plan' allow false ''
case_ true  "issue opened by a human"           '[]' issues opened '' agent:triage alice false '' 'triage plan' allow false ''
case_ true  "comment @claude triage"            '[]' issue_comment created '' agent:triage alice false '@claude triage this' 'triage plan' allow false ''
case_ true  "comment @claude plan"              '[]' issue_comment created '' agent:triage alice false 'please @claude plan it' 'triage plan' allow false ''
case_ false "comment /triage (verb retired)"    '[]' issue_comment created '' agent:triage alice false '/triage' 'triage plan' allow false ''
case_ false "comment @claude <anything else>"   '[]' issue_comment created '' agent:triage alice false '@claude what is this' 'triage plan' allow false ''

echo "== pr review =="
case_ false "draft PR"                          '[]' pull_request ready_for_review '' agent:review alice true '' '' reject true 'src/a.ts'
case_ false "renovate PR (deps-verify owns it)" '[]' pull_request opened '' agent:review 'renovate[bot]' false '' '' reject true 'p.json'
case_ false "docs-only change"                  '[]' pull_request ready_for_review '' agent:review alice false '' '' reject true 'README.md
docs/x.md'
case_ true  "docs + code"                       '[]' pull_request ready_for_review '' agent:review alice false '' '' reject true 'README.md
src/a.ts'
case_ true  "labeled agent:review"              '["agent:review"]' pull_request labeled agent:review agent:review alice false '' '' reject true 'src/a.ts'

echo "== deps-verify (bots: only) =="
case_ true  "renovate PR"                       '[]' pull_request opened '' agent:review 'renovate[bot]' false '' '' only true ''
case_ false "human PR"                          '[]' pull_request opened '' agent:review alice false '' '' only true ''
case_ true  "dependabot PR"                     '[]' pull_request synchronize '' agent:review 'dependabot[bot]' false '' '' only true ''
case_ true  "renovate + labeled agent:review"   '[]' pull_request labeled agent:review agent:review 'renovate[bot]' false '' '' only true ''
case_ false "renovate + labeled deps:major"     '[]' pull_request labeled deps:major agent:review 'renovate[bot]' false '' '' only true ''

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
