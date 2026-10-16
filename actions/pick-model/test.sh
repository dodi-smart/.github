#!/usr/bin/env bash
# The model policy as a matrix. Each row is a stage, the issue fields and the
# signals a workflow passes, and the model and cap that must come out.
#
# Run: actions/pick-model/test.sh   (bash 3.2 and 5)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pick-model-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The ids come from pick.sh, so a model bump stays one edit.
id() { sed -n "s/^$1='\(.*\)'$/\1/p" "$HERE/pick.sh"; }
OPUS=$(id OPUS); SONNET=$(id SONNET); HAIKU=$(id HAIKU)
[ -n "$OPUS" ] && [ -n "$SONNET" ] && [ -n "$HAIKU" ] || { echo "cannot read the model ids from pick.sh"; exit 1; }
pass=0; fail=0

# pick <desc> <want model> <want max-turns> [ENV=value ...]
pick() {
  local desc="$1" want="$2" wantturns="$3"; shift 3
  export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
  env STAGE= EFFORT= PRIORITY= RISK= SIGNALS= ROUND= MODEL= PIN= MAX_TURNS= "$@" \
    bash "$HERE/pick.sh" >"$TMP/log" 2>&1
  local got turns
  got=$(sed -n 's/^model=//p' "$GITHUB_OUTPUT"); turns=$(sed -n 's/^max-turns=//p' "$GITHUB_OUTPUT")
  if [ "$got" = "$want" ] && [ "$turns" = "$wantturns" ]; then printf '  ok   %s\n' "$desc"; pass=$((pass+1))
  else printf '  FAIL %s: wanted %s/%s, got %s/%s\n' "$desc" "$want" "${wantturns:-none}" "$got" "${turns:-none}"; fail=$((fail+1)); fi
}

echo "== planning and open-ended work =="
pick "triage, Risk Low"                         "$OPUS"   ""  STAGE=triage RISK=Low
pick "assist"                                   "$OPUS"   ""  STAGE=assist

echo "== implement escalates on the fields =="
pick "implement Low/Low, Priority Medium"       "$SONNET" ""  STAGE=implement RISK=Low EFFORT=Low PRIORITY=Medium
pick "implement Medium/Medium, Priority unset"  "$SONNET" ""  STAGE=implement RISK=Medium EFFORT=Medium
pick "implement Effort High"                    "$OPUS"   ""  STAGE=implement RISK=Low EFFORT=High
pick "implement Risk High"                      "$OPUS"   ""  STAGE=implement RISK=High EFFORT=Low
pick "implement Risk Critical"                  "$OPUS"   ""  STAGE=implement RISK=Critical EFFORT=Low
pick "implement Priority Urgent"                "$OPUS"   ""  STAGE=implement RISK=Low EFFORT=Low PRIORITY=Urgent
pick "implement with no fields"                 "$OPUS"   ""  STAGE=implement
pick "implement with Risk unset"                "$OPUS"   ""  STAGE=implement EFFORT=Low

echo "== fix rounds =="
pick "fix-ci round 1, Risk Low"                 "$SONNET" 60  STAGE=fix-ci ROUND=1 RISK=Low EFFORT=Low
pick "fix-ci round 1, lint only"                "$HAIKU"  30  STAGE=fix-ci ROUND=1 RISK=Low EFFORT=Low SIGNALS=lint-only
pick "fix-ci round 2, lint only"                "$OPUS"   60  STAGE=fix-ci ROUND=2 RISK=Low EFFORT=Low SIGNALS=lint-only
pick "fix-ci round 1, lint only, Risk High"     "$OPUS"   60  STAGE=fix-ci ROUND=1 RISK=High SIGNALS=lint-only
pick "fix-ci with no round given is round 1"    "$SONNET" 60  STAGE=fix-ci RISK=Low EFFORT=Low
pick "fix-review round 1"                       "$OPUS"   60  STAGE=fix-review ROUND=1 RISK=Low

echo "== review =="
pick "review, full"                             "$OPUS"   ""  STAGE=review SIGNALS=full
pick "review, scoped"                           "$SONNET" ""  STAGE=review SIGNALS=scoped
pick "review, scoped and elevated"              "$OPUS"   ""  STAGE=review "SIGNALS=scoped elevated"

echo "== deps-verify =="
pick "green patch"                              "$HAIKU"  30  STAGE=deps-verify SIGNALS=patch
pick "green lockfile"                           "$HAIKU"  30  STAGE=deps-verify SIGNALS=lockfile
pick "green minor"                              "$SONNET" 40  STAGE=deps-verify SIGNALS=minor
pick "green, update kind unknown"               "$SONNET" 40  STAGE=deps-verify SIGNALS=unknown
pick "red patch"                                "$OPUS"   80  STAGE=deps-verify "SIGNALS=red patch"
pick "green major"                              "$OPUS"   40  STAGE=deps-verify SIGNALS=major

echo "== fleet-sync =="
pick "fleet-sync"                               "$SONNET" 40  STAGE=fleet-sync

echo "== overrides =="
pick "caller override beats policy"             "my-model" "" STAGE=triage MODEL=my-model
pick "pin beats override"                       "pinned"   "" STAGE=triage MODEL=my-model PIN=pinned
pick "caller max-turns beats policy"            "$SONNET" 99  STAGE=fleet-sync MAX_TURNS=99
pick "stage and fields are case-insensitive"    "$OPUS"   ""  STAGE=Implement RISK=low EFFORT=HIGH

echo "== a caller from before stages =="
pick "no stage, a model: the caller's model"    "claude-sonnet-5" "40" MODEL=claude-sonnet-5 MAX_TURNS=40
if grep -q '::warning title=No agent stage' "$TMP/log"; then printf '  ok   and it warns\n'; pass=$((pass+1))
else printf '  FAIL no warning\n'; fail=$((fail+1)); fi
pick "no stage, a model, the pin still wins"    "pinned"  ""  MODEL=claude-sonnet-5 PIN=pinned
: > "$GITHUB_OUTPUT"
if env STAGE= MODEL= bash "$HERE/pick.sh" >"$TMP/log" 2>&1; then printf '  FAIL no stage and no model exits 0\n'; fail=$((fail+1))
else printf '  ok   no stage and no model fails\n'; pass=$((pass+1)); fi

echo "== an unknown stage fails =="
export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
if env STAGE=plan bash "$HERE/pick.sh" >"$TMP/log" 2>&1; then
  printf '  FAIL unknown stage exits 0\n'; fail=$((fail+1))
elif grep -q '::error title=Unknown agent stage' "$TMP/log" && ! grep -q '^model=' "$GITHUB_OUTPUT"; then
  printf '  ok   unknown stage fails with an error and picks nothing\n'; pass=$((pass+1))
else printf '  FAIL unknown stage: no error or a model was written\n'; fail=$((fail+1)); fi

echo "== an unknown signal fails =="
: > "$GITHUB_OUTPUT"
if env STAGE=fix-ci SIGNALS=lint_only bash "$HERE/pick.sh" >"$TMP/log" 2>&1; then
  printf '  FAIL a misspelt signal exits 0\n'; fail=$((fail+1))
elif grep -q '::error title=Unknown agent signal' "$TMP/log"; then
  printf '  ok   a misspelt signal fails instead of being ignored\n'; pass=$((pass+1))
else printf '  FAIL a misspelt signal: no error\n'; fail=$((fail+1)); fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
