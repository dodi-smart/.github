#!/usr/bin/env bash
# Assert when the merge gate merges. The costly mistake is a merge that should
# not have happened, so every refusal comes before the merges. agent-gate's own
# rules (agent:no-touch, draft, author kind) are tested in actions/agent-gate.
# The stub bodies are single-quoted on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# $1 name, $2 want merge (true, false, or rebase), then env assignments. The default is a mergeable
# verified minor with a green check and only allowed authors.
decide() {
  local name="$1" want="$2" got m r; shift 2
  got="$(env -i PATH="$PATH" POLICY=deps LABELS='["deps:verified","deps:minor"]' TITLE='chore(deps): update x' \
         CHECK=success REVIEW='' FOREIGN='' KILL='' "$@" "$HERE/gate.sh" decide)"
  m=$(sed -n 's/^merge=//p' <<<"$got"); r=$(sed -n 's/^reason=//p' <<<"$got")
  [ "$(sed -n 's/^rebase=//p' <<<"$got")" = true ] && m=rebase
  if [ "$m" = "$want" ]; then ok "$(printf '%-58s -> %s (%s)' "$name" "$m" "$r")"
  else bad "$(printf '%-58s -> %s (wanted %s: %s)' "$name" "$m" "$want" "$r")"; fi
}

decide "the kill switch is 'false'"                               false KILL=false
decide "a kill switch set to anything else does not stop it"      true  KILL=true
decide "an unknown policy"                                        false POLICY=nope

decide "a major, verified and green"                              false 'LABELS=["deps:verified","deps:major"]'
decide "a group with one major among minors"                      false 'LABELS=["deps:verified","deps:minor","deps:patch","deps:major"]'
decide "no kind label and an unreadable title"                    false 'LABELS=["deps:verified"]'

decide "no verdict label yet"                                     false 'LABELS=["deps:minor"]'
decide "deps:needs-manual"                                        false 'LABELS=["deps:needs-manual","deps:minor"]'
decide "needs-manual beside verified (a Renovate rule's label)"   false 'LABELS=["deps:verified","deps:needs-manual","deps:minor"]'
decide "deps:fixed with no review status"                         false 'LABELS=["deps:fixed","deps:patch"]'
decide "deps:fixed with the review asking for changes"            false 'LABELS=["deps:fixed","deps:patch"]' REVIEW=failure
decide "deps:fixed with a pending review status"                  false 'LABELS=["deps:fixed","deps:patch"]' REVIEW=pending
decide "fixed beside verified still waits for the review"         false 'LABELS=["deps:fixed","deps:verified","deps:patch"]'

decide "verified, but the required check failed"                  false CHECK=failure
decide "verified, but the required check is still running"        false CHECK=in_progress
decide "verified, but the required check has not reported"        false CHECK=
decide "fixed and approved, but the required check failed"        false 'LABELS=["deps:fixed","deps:patch"]' REVIEW=success CHECK=failure
decide "a commit by an author the policy does not merge"          false FOREIGN='someone'

decide "minimum release age not met (stability-days pending)"     false AGE=pending
decide "release age pending on a conflicted PR waits, no rebase"  false AGE=pending MERGEABLE=dirty
decide "release age pending, deps:fixed and approved"             false AGE=pending 'LABELS=["deps:fixed","deps:patch"]' REVIEW=success
decide "a conflicted verified PR asks for a rebase"               rebase MERGEABLE=dirty
decide "a conflicted fixed PR asks for a rebase, not a review"    rebase MERGEABLE=dirty 'LABELS=["deps:fixed","deps:patch"]'
decide "a conflicted major is not rebased by the gate"            false MERGEABLE=dirty 'LABELS=["deps:verified","deps:major"]'
decide "a conflicted needs-manual is not rebased by the gate"     false MERGEABLE=dirty 'LABELS=["deps:needs-manual","deps:minor"]'
decide "the kill switch beats a rebase"                           false MERGEABLE=dirty KILL=false
decide "factory ignores the deps age and conflict rules"          true  POLICY=factory 'LABELS=["agent:iterate"]' TIER=merge REVIEW=success AGE=pending

F='POLICY=factory'; FL='LABELS=["agent:iterate"]'
decide "factory: no agent:iterate"                                false "$F" 'LABELS=[]' TIER=merge REVIEW=success
decide "factory: agent:no-touch on the issue"                     false "$F" "$FL" TIER=merge REVIEW=success ISSUE_NO_TOUCH=true
decide "factory: tier ready"                                      false "$F" "$FL" TIER=ready REVIEW=success
decide "factory: tier draft"                                      false "$F" "$FL" TIER=draft REVIEW=success
decide "factory: no tier read"                                    false "$F" "$FL" TIER= REVIEW=success
decide "factory: review asks for changes"                         false "$F" "$FL" TIER=merge REVIEW=failure
decide "factory: no review status"                                false "$F" "$FL" TIER=merge REVIEW=
decide "factory: approved, but the check failed"                  false "$F" "$FL" TIER=merge REVIEW=success CHECK=failure
decide "factory: approved, but a person committed"                false "$F" "$FL" TIER=merge REVIEW=success FOREIGN=someone
decide "factory: merge tier, approved, green"                     true  "$F" "$FL" TIER=merge REVIEW=success
decide "factory: the branch conflicts with its base"              false "$F" "$FL" TIER=merge REVIEW=success MERGEABLE=dirty
decide "factory: behind its base is not a conflict"               true  "$F" "$FL" TIER=merge REVIEW=success MERGEABLE=behind
decide "factory: mergeable state not computed yet"                true  "$F" "$FL" TIER=merge REVIEW=success MERGEABLE=unknown

decide "verified minor, green"                                    true
decide "verified minor, release age met, mergeable"               true  AGE=success MERGEABLE=clean
decide "verified minor, mergeable state not computed yet"         true  MERGEABLE=unknown
decide "verified patch, green"                                    true  'LABELS=["deps:verified","deps:patch"]'
decide "verified lock file maintenance, green"                    true  'LABELS=["deps:verified"]' TITLE='chore(deps): lock file maintenance'
decide "fixed patch, approved, green"                             true  'LABELS=["deps:fixed","deps:patch"]' REVIEW=success
decide "a Dependabot minor by title, verified, green"             true  'LABELS=["deps:verified"]' TITLE='Bump react from 19.0.0 to 19.1.0'

# A conflicted agent PR is held with the loop's own reason, and no rebase box.
got="$(env -i PATH="$PATH" POLICY=factory 'LABELS=["agent:iterate"]' TIER=merge REVIEW=success CHECK=success MERGEABLE=dirty "$HERE/gate.sh" decide)"
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
check "factory dirty: the reason says the loop brings it up to date" \
  grep -qx 'reason=the branch conflicts with its base; the fix loop brings it up to date' <<<"$got"
check "factory dirty: it is not a rebase request" grep -qx 'rebase=false' <<<"$got"

# squash-body: the trailers of every commit on the PR, one base64 message per
# line (as the API step feeds it), each once, in the order first seen.
msgs() { local m; for m in "$@"; do printf '%s' "$m" | base64 | tr -d '\n'; echo; done; }
body="$(msgs $'feat: x\n\nFactory-Round: 0\nFactory-Issue: 4\nDecision: D-1' \
             $'fix: y\n\nnot: a trailer\n\nFactory-Round: 1\nDecision: D-1\nCo-Authored-By: A <a@example.com>' \
             $'Merge remote-tracking branch \'origin/main\' into feat/4-x\n\nFactory-Round: 2' \
             'chore: no trailers at all' | "$HERE/gate.sh" squash-body)"
check "squash-body keeps each round trailer, in order" \
  test "$body" = $'Factory-Round: 0\nFactory-Issue: 4\nDecision: D-1\nFactory-Round: 1\nCo-Authored-By: A <a@example.com>\nFactory-Round: 2'
check "squash-body of nothing is empty" test -z "$(: | "$HERE/gate.sh" squash-body)"

# `run` reads the check, the authors and the review only when a verdict label
# makes them matter. `gh` is a stub that records its calls.
mkdir -p "$WORK/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$STUB_CALLS"' 'case "$*" in' \
  '  *check-runs*) echo "$STUB_CHECK" ;;' \
  '  *"/commits?"*) printf "%s\n" $STUB_AUTHORS ;;' \
  '  */status*) echo "$STUB_STATUSES" ;;' 'esac' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
# run LABELS AUTHORS CHECK REVIEW [AGE] [MERGEABLE]
run() {
  : > "$WORK/calls"; : > "$WORK/out"
  local st; st=$(jq -cn --arg r "$4" --arg a "${5:-}" \
    '[if $r != "" then {context: "review / verdict", state: $r} else empty end,
      if $a != "" then {context: "renovate/stability-days", state: $a} else empty end]')
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" STUB_CHECK="$3" STUB_STATUSES="$st" STUB_AUTHORS="$2" \
    MERGEABLE="${6:-clean}" \
    POLICY=deps REPO=o/r PR=7 SHA=abc LABELS="$1" TITLE='chore(deps): update x' KILL='' \
    REQUIRED_CHECK='checks / PR Checks' ALLOWED_AUTHORS='renovate[bot],dependabot[bot],github-actions[bot]' \
    GITHUB_OUTPUT="$WORK/out" "$HERE/gate.sh" run > /dev/null 2>&1
}
run '["deps:fixed","deps:patch"]' 'renovate[bot] github-actions[bot]' success success
check "run: a fixed, approved patch by allowed authors merges"   grep -qx 'merge=true' "$WORK/out"
check "run: the check name is URL-encoded"                       grep -qF 'check_name=checks%20%2F%20PR%20Checks' "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot] someone' success ''
check "run: a stranger's commit stops it"                        grep -qx 'reason=a commit is by an author this policy does not merge: someone' "$WORK/out"
run '["deps:minor"]' 'renovate[bot]' success success
check "run: no verdict label reads nothing else"                 bash -c '! grep -qE "check-runs|commits|status" "$1"' _ "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot]' success ''
check "run: verified reads the check and the statuses once"     bash -c 'grep -q check-runs "$1" && [ "$(grep -c "/status" "$1")" = 1 ]' _ "$WORK/calls"
check "run: and merges"                                          grep -qx 'merge=true' "$WORK/out"
run '["deps:verified","deps:patch"]' 'renovate[bot]' success '' pending
check "run: a pending stability-days status holds the merge"     grep -qx 'merge=false' "$WORK/out"
run '["deps:verified","deps:patch"]' 'renovate[bot]' success '' success dirty
check "run: a conflicted PR asks for a rebase"                   grep -qx 'rebase=true' "$WORK/out"
run '["deps:fixed","deps:patch"]' 'renovate[bot]' success success success
check "run: the review is read from the same status read"        grep -qx 'merge=true' "$WORK/out"

# tick: the rebase request's edit to Renovate's PR body.
tick() { printf '%b' "$1" | "$HERE/gate.sh" tick; }
got=$(tick 'notes\n - [ ] <!-- rebase-check -->If you want to rebase\nend'); rc=$?
check "tick: an empty box is ticked, nothing else changes"       test "$rc:$got" = "0:notes
 - [x] <!-- rebase-check -->If you want to rebase
end"
tick ' - [x] <!-- rebase-check -->' > /dev/null; rc=$?
check "tick: a ticked box is left, exit 3"                       test "$rc" = 3
tick 'a Dependabot body' > /dev/null; rc=$?
check "tick: no box, exit 4"                                     test "$rc" = 4

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
