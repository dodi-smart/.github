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

# gd [VAR=value ...]: gate.sh decide on a green check into the default branch, nothing else set.
gd() { env -i PATH="$PATH" LABELS='[]' TITLE='fix: x' CHECK=success REVIEW='' FOREIGN='' KILL='' \
         BASE_REF=develop DEFAULT_BRANCH=develop "$@" "$HERE/gate.sh" decide; }

# $1 name, $2 want merge (true, false, or rebase), then env assignments. The default is a mergeable
# verified minor into the default branch with a green check and only allowed authors.
decide() {
  local name="$1" want="$2" got m r; shift 2
  got="$(gd POLICY=deps LABELS='["deps:verified","deps:minor"]' TITLE='chore(deps): update x' "$@")"
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

# deps: only the default branch takes unattended dependency merges.
decide "deps into a non-default base (a security update to main)" false BASE_REF=main
decide "deps into a release branch, fixed and approved"           false BASE_REF=main 'LABELS=["deps:fixed","deps:patch"]' REVIEW=success
decide "deps with the base unreadable"                            false BASE_REF=
decide "deps with the default branch unreadable"                  false DEFAULT_BRANCH=
decide "deps into main when main is the default branch"           true  BASE_REF=main DEFAULT_BRANCH=main
decide "factory does not read the base"                           true  POLICY=factory 'LABELS=["agent:iterate"]' TIER=merge REVIEW=success BASE_REF=main

# backmerge: a clean merge of the release branch into the default branch.
B='POLICY=backmerge'; BL='LABELS=[]'
decide "backmerge: clean merge, both parents in place, green"     true  "$B" "$BL" HEAD_REF=chore/backmerge-v1.2.3 PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: parents equal to the branch heads"             true  "$B" "$BL" HEAD_REF=chore/backmerge-v1.2.3 PARENTS=2 P1_REL=identical P2_REL=identical
decide "backmerge: the kill switch is 'false'"                    false "$B" "$BL" HEAD_REF=chore/backmerge-v1.2.3 PARENTS=2 P1_REL=ahead P2_REL=ahead KILL=false
decide "backmerge: a head branch of another name"                 false "$B" "$BL" HEAD_REF=fix/security-x PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: a branch that only resembles the prefix"       false "$B" "$BL" HEAD_REF=chore/backmerges PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: the bare prefix with no tag"                   false "$B" "$BL" HEAD_REF=chore/backmerge- PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: no head branch"                                false "$B" "$BL" PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: the base is not the default branch"            false "$B" "$BL" HEAD_REF=chore/backmerge-v1 BASE_REF=main PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: the default branch unreadable"                 false "$B" "$BL" HEAD_REF=chore/backmerge-v1 DEFAULT_BRANCH= PARENTS=2 P1_REL=ahead P2_REL=ahead
decide "backmerge: the required check failed"                     false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead CHECK=failure
decide "backmerge: the required check is still running"           false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead CHECK=in_progress
decide "backmerge: the required check has not reported"           false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead CHECK=
decide "backmerge: the branch conflicts with its base"            false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead MERGEABLE=dirty
decide "backmerge: behind its base is not a conflict"             true  "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead MERGEABLE=behind
decide "backmerge: mergeable state not computed yet"              true  "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead MERGEABLE=unknown
decide "backmerge: a person pushed a commit on top (one parent)"  false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=1 P1_REL=ahead P2_REL=ahead
decide "backmerge: an octopus merge (three parents)"              false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=3 P1_REL=ahead P2_REL=ahead
decide "backmerge: the parents were not read"                     false "$B" "$BL" HEAD_REF=chore/backmerge-v1
decide "backmerge: the first parent is not in the base"           false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=diverged P2_REL=ahead
decide "backmerge: the first parent is ahead of the base"         false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=behind P2_REL=ahead
decide "backmerge: the second parent is not in the release"       false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=diverged
decide "backmerge: the second parent could not be compared"       false "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=
decide "backmerge: every author is allowed to have committed"     true  "$B" "$BL" HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead FOREIGN=someone

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

# The new policies' PR shapes, shared with the says and wants cases below: a
# security patch into main, the App's pure sync, a regenerated back-merge.
HF=(POLICY=hotfix 'LABELS=[]' BASE_REF=main)
SY=(POLICY=standards-sync 'LABELS=[]' HEAD_REF=chore/standards-sync APP_BOT='app[bot]' AUTHOR='app[bot]' VERIFY=success RENDER=success)
BR=(POLICY=backmerge 'LABELS=["backmerge:regenerated"]' HEAD_REF=chore/backmerge-v1 PARENTS=2 P1_REL=ahead P2_REL=ahead)

# backmerge:regenerated: the rebuilt lock file needs an approving review too.
decide "backmerge regenerated: approved, green"                   true  "${BR[@]}" REVIEW=success

# hotfix: a security patch on the lane into the release branch.
decide "hotfix: lane, approved, green"                            true  "${HF[@]}" LANE=lane REVIEW=success
decide "hotfix: a person wrote it (no author rule)"               true  "${HF[@]}" LANE=lane REVIEW=success FOREIGN=someone
decide "hotfix: another release branch name"                      true  "${HF[@]}" BASE_REF=release RELEASE_BRANCH=release LANE=lane REVIEW=success
decide "hotfix: the base unreadable"                              false "${HF[@]}" BASE_REF= LANE=lane REVIEW=success
decide "hotfix: verdict release"                                  false "${HF[@]}" LANE=release REVIEW=success
decide "hotfix: verdict reject"                                   false "${HF[@]}" LANE=reject REVIEW=success
decide "hotfix: a pending review"                                 false "${HF[@]}" LANE=lane REVIEW=pending
decide "hotfix: approved, but the check failed"                   false "${HF[@]}" LANE=lane REVIEW=success CHECK=failure
decide "hotfix: approved, but the check has not reported"         false "${HF[@]}" LANE=lane REVIEW=success CHECK=
decide "hotfix: the branch conflicts with its base"               false "${HF[@]}" LANE=lane REVIEW=success MERGEABLE=dirty

# standards-sync: the org App's pure sync into the default branch.
decide "sync: pure, verified, approved, green"                    true  "${SY[@]}" REVIEW=success
decide "sync: the App's login unreadable"                         false "${SY[@]}" APP_BOT= REVIEW=success
decide "sync: a commit by someone else"                           false "${SY[@]}" REVIEW=success FOREIGN=someone
decide "sync: no render status"                                   false "${SY[@]}" RENDER= REVIEW=success
decide "sync: no verify status"                                   false "${SY[@]}" VERIFY= REVIEW=success
decide "sync: approved, but the check failed"                     false "${SY[@]}" REVIEW=success CHECK=failure
decide "sync: the branch conflicts with its base"                 false "${SY[@]}" REVIEW=success MERGEABLE=dirty

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

# Each refusal of the new rules says exactly why (these cases are not repeated
# above). says NAME REASON [VAR=value ...] asserts merge=false and that reason;
# wants NAME true|false [...] asserts review-wanted (a missing review on a
# candidate has merge-gate request one).
says() { local name="$1" want="$2" got; shift 2; got="$(gd "$@")"
  if grep -qx 'merge=false' <<<"$got" && grep -qxF "reason=$want" <<<"$got"; then ok "says: $name"
  else bad "says: $name (wanted '$want', got '$(sed -n 's/^reason=//p' <<<"$got")')"; fi; }
wants() { local name="$1" want="$2"; shift 2
  check "review-wanted=$want: $name" grep -qx "review-wanted=$want" <<<"$(gd "$@")"; }
says "hotfix, a non-lane verdict" "target-guard's verdict is skip, not lane: the base is not the release branch (main)" \
  "${HF[@]}" LANE=skip LANE_REASON='the base is not the release branch (main)' REVIEW=success
says "hotfix, no verdict read" "target-guard's verdict is unreadable, not lane" "${HF[@]}" REVIEW=success
says "hotfix, no review" "a security patch on the hotfix lane waits for review / verdict, which the head does not have yet" "${HF[@]}" LANE=lane
says "hotfix, a changes verdict" "a security patch on the hotfix lane: review / verdict asks for changes" "${HF[@]}" LANE=lane REVIEW=failure
says "hotfix, the kill switch off" "the kill switch is 'false'" "${HF[@]}" LANE=lane REVIEW=success KILL=false
says "hotfix, a wrong base" "the base is develop, not the release branch main" POLICY=hotfix LANE=lane REVIEW=success
says "sync, a non-pure render" "the render is not pure (standards / render is failure): an agent-touched sync waits for a person" \
  "${SY[@]}" RENDER=failure REVIEW=success
says "sync, new verify failures" "standards / verify is failure: the sync may add verify failures, so a person merges it" \
  "${SY[@]}" VERIFY=failure REVIEW=success
says "sync, the kill switch off" "the kill switch is 'false'" "${SY[@]}" REVIEW=success KILL=false
says "sync, a wrong head" "the head branch is chore/other, not chore/standards-sync" "${SY[@]}" HEAD_REF=chore/other REVIEW=success
says "sync, a wrong base" "the base is main, not the default branch develop" "${SY[@]}" BASE_REF=main REVIEW=success
says "sync, not the App's PR" "the PR is by someone, not the org App (app[bot])" "${SY[@]}" AUTHOR=someone REVIEW=success
says "sync, no review" "a standards sync waits for review / verdict, which the head does not have yet" "${SY[@]}"
says "backmerge regenerated, no review" \
  "a back-merge whose lock file was regenerated (backmerge:regenerated) waits for review / verdict, which the head does not have yet" "${BR[@]}"
says "backmerge regenerated, a changes verdict" \
  "a back-merge whose lock file was regenerated (backmerge:regenerated): review / verdict asks for changes" "${BR[@]}" REVIEW=failure
wants "a lane PR with no review"                    true  "${HF[@]}" LANE=lane
wants "a lane PR with no review and a red check"    true  "${HF[@]}" LANE=lane CHECK=failure
wants "a lane PR already reviewed"                  false "${HF[@]}" LANE=lane REVIEW=failure
wants "a lane PR whose review is in flight"         false "${HF[@]}" LANE=lane 'LABELS=["agent:review"]'
wants "a non-lane PR"                               false "${HF[@]}" LANE=skip
wants "a lane PR with the kill switch off"          false "${HF[@]}" LANE=lane KILL=false
wants "an agent-touched sync is still reviewed"     true  "${SY[@]}" RENDER=failure
wants "a sync by someone else"                      false "${SY[@]}" AUTHOR=someone
wants "a regenerated back-merge with no review"     true  "${BR[@]}"
wants "a plain back-merge"                          false "${BR[@]}" 'LABELS=[]'
wants "a deps:fixed PR (deps-verify asks for it)"   false POLICY=deps 'LABELS=["deps:fixed","deps:patch"]' TITLE='chore(deps): update x'

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
  '  *custom_properties*) echo "$STUB_HOTFIX" ;;' \
  '  *commit.message*) echo "$STUB_MESSAGES" ;;' \
  '  */compare/p1...*) echo "$STUB_P1" ;;' \
  '  */compare/p2...*) echo "$STUB_P2" ;;' \
  '  */commits/abc\ --jq*) printf "%s\n" $STUB_PARENTS ;;' \
  '  "api /repos/o/r --jq"*) echo "$STUB_DEFAULT" ;;' \
  '  *"/commits?"*) printf "%s\n" $STUB_AUTHORS ;;' \
  '  */status*) echo "$STUB_STATUSES" ;;' 'esac' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
# run LABELS AUTHORS CHECK REVIEW AGE [VAR=value ...]. The defaults are a
# mergeable deps PR into develop (the default branch), whose head has parents p1
# and p2 that sit in place; trailing assignments override them, as in decide.
run() {
  : > "$WORK/calls"; : > "$WORK/out"
  local labels="$1" authors="$2" check="$3" st; st=$(jq -cn --arg r "$4" --arg a "$5" \
    '[if $r != "" then {context: "review / verdict", state: $r} else empty end,
      if $a != "" then {context: "renovate/stability-days", state: $a} else empty end]')
  shift 5
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" STUB_CHECK="$check" STUB_STATUSES="$st" STUB_AUTHORS="$authors" \
    STUB_DEFAULT=develop STUB_PARENTS='p1 p2' STUB_P1=ahead STUB_P2=ahead \
    MERGEABLE=clean BASE_REF=develop DEFAULT_BRANCH=develop \
    POLICY=deps REPO=o/r PR=7 SHA=abc LABELS="$labels" TITLE='chore(deps): update x' KILL='' \
    REQUIRED_CHECK='checks / PR Checks' ALLOWED_AUTHORS='renovate[bot],dependabot[bot],github-actions[bot]' \
    GITHUB_OUTPUT="$WORK/out" "$@" "$HERE/gate.sh" run > /dev/null 2>&1
}
run '["deps:fixed","deps:patch"]' 'renovate[bot] github-actions[bot]' success success ''
check "run: a fixed, approved patch by allowed authors merges"   grep -qx 'merge=true' "$WORK/out"
check "run: the check name is URL-encoded"                       grep -qF 'check_name=checks%20%2F%20PR%20Checks' "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot] someone' success '' ''
check "run: a stranger's commit stops it"                        grep -qx 'reason=a commit is by an author this policy does not merge: someone' "$WORK/out"
run '["deps:minor"]' 'renovate[bot]' success success ''
check "run: no verdict label reads nothing else"                 bash -c '! grep -qE "check-runs|commits|status" "$1"' _ "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot]' success '' ''
check "run: verified reads the check and the statuses once"     bash -c 'grep -q check-runs "$1" && [ "$(grep -c "/status" "$1")" = 1 ]' _ "$WORK/calls"
check "run: and merges"                                          grep -qx 'merge=true' "$WORK/out"
run '["deps:verified","deps:patch"]' 'renovate[bot]' success '' pending
check "run: a pending stability-days status holds the merge"     grep -qx 'merge=false' "$WORK/out"
run '["deps:verified","deps:patch"]' 'renovate[bot]' success '' success MERGEABLE=dirty
check "run: a conflicted PR asks for a rebase"                   grep -qx 'rebase=true' "$WORK/out"
run '["deps:fixed","deps:patch"]' 'renovate[bot]' success success success
check "run: the review is read from the same status read"        grep -qx 'merge=true' "$WORK/out"

# The default branch arrives from pr-facts, and is read only when it is empty.
# backmerge reads the head's parents and compares each, and no commit authors.
run '["deps:verified","deps:minor"]' 'renovate[bot]' success '' ''
check "run: deps takes the default branch it is given"           bash -c '! grep -q -- "^api /repos/o/r --jq" "$1"' _ "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot]' success '' '' DEFAULT_BRANCH=
check "run: an empty default branch is read from the API"        grep -q -- '^api /repos/o/r --jq' "$WORK/calls"
check "run: and then merges"                                     grep -qx 'merge=true' "$WORK/out"
run '["deps:verified","deps:minor"]' 'renovate[bot]' success '' '' BASE_REF=main
check "run: deps into main (not the default) is held"            grep -qx 'merge=false' "$WORK/out"
check "run: and says why"                                        grep -q '^reason=a dependency update into main waits for a person' "$WORK/out"

# bm [VAR=value ...]: a back-merge from chore/backmerge-v1.2.3, no labels or statuses.
bm() { run '[]' '' success '' '' POLICY=backmerge HEAD_REF=chore/backmerge-v1.2.3 "$@"; }
bm
check "run: a clean back-merge merges"                           grep -qx 'merge=true' "$WORK/out"
check "run: it compares each parent with its branch"             bash -c 'grep -q "compare/p1...develop" "$1" && grep -q "compare/p2...main" "$1"' _ "$WORK/calls"
check "run: it reads the check but no commit authors"            bash -c 'grep -q check-runs "$1" && ! grep -q "pulls/7/commits" "$1"' _ "$WORK/calls"
bm STUB_P1=identical STUB_P2=identical
check "run: parents equal to the branch heads merge"             grep -qx 'merge=true' "$WORK/out"
bm STUB_P1=diverged
check "run: a first parent outside the base is held"             grep -qx 'merge=false' "$WORK/out"
bm STUB_P2=diverged
check "run: a second parent outside the release is held"         grep -qx 'merge=false' "$WORK/out"
bm STUB_PARENTS=p1
check "run: a one-parent head is held"                           grep -qx 'merge=false' "$WORK/out"
bm STUB_CHECK=failure
check "run: a failed check holds it"                             grep -qx 'merge=false' "$WORK/out"
bm HEAD_REF=fix/security-x
check "run: another head branch reads no parents"                bash -c '! grep -q "commits/abc --jq" "$1"' _ "$WORK/calls"
check "run: and is held"                                         grep -qx 'merge=false' "$WORK/out"
bm BASE_REF=main
check "run: a base that is not the default reads no parents"     bash -c '! grep -q "commits/abc --jq" "$1"' _ "$WORK/calls"
check "run: and is held too"                                     grep -qx 'merge=false' "$WORK/out"

# hf [VAR=value ...]: a security patch from fix/security-x into main, on a repo
# with the lane enabled, a fix commit and an approving review.
APPROVED='[{"context":"review / verdict","state":"success"}]'
hf() { run '[]' 'someone' success '' '' POLICY=hotfix BASE_REF=main HEAD_REF=fix/security-x TITLE='fix: patch x' \
         STUB_HOTFIX=enabled STUB_MESSAGES='["fix: patch x"]' STUB_STATUSES="$APPROVED" "$@"; }
hf
check "run: an approved lane PR merges"                          grep -qx 'merge=true' "$WORK/out"
check "run: it derives the lane verdict from the live PR"        bash -c 'grep -q custom_properties "$1" && grep -q "commit.message" "$1"' _ "$WORK/calls"
check "run: and reads no commit authors"                         bash -c '! grep -q "author.login" "$1"' _ "$WORK/calls"
hf STUB_HOTFIX=disabled
check "run: a repo without the lane is held"                     grep -q "^reason=target-guard's verdict is reject, not lane: a security patch cannot target" "$WORK/out"
hf STUB_MESSAGES='["feat: x"]'
check "run: a feature commit on the patch is held"               grep -q "^reason=target-guard's verdict is reject, not lane: .*a commit is a feature" "$WORK/out"
hf TITLE='chore: x'
check "run: a non-fix title is held"                             grep -qx 'merge=false' "$WORK/out"
hf STUB_STATUSES='[]'
check "run: an unreviewed lane PR asks for a review"             bash -c 'grep -qx merge=false "$1" && grep -qx review-wanted=true "$1"' _ "$WORK/out"
hf MERGEABLE=dirty
check "run: a conflicted lane PR is held for the conflict"       grep -qx 'reason=the security patch conflicts with main: a person resolves it' "$WORK/out"
hf KILL=false
check "run: the kill switch off reads nothing"                   test ! -s "$WORK/calls"
check "run: and the switch holds it"                            grep -qx "reason=the kill switch is 'false'" "$WORK/out"
hf BASE_REF=develop
check "run: a patch into develop reads no lane property"         bash -c '! grep -q custom_properties "$1"' _ "$WORK/calls"
check "run: and is held"                                         grep -qx 'merge=false' "$WORK/out"

# sy [VAR=value ...]: the App's pure, approved sync into develop.
PURE='[{"context":"review / verdict","state":"success"},{"context":"standards / verify","state":"success"},{"context":"standards / render","state":"success"}]'
sy() { run '[]' 'app[bot]' success '' '' POLICY=standards-sync HEAD_REF=chore/standards-sync AUTHOR='app[bot]' APP_BOT='app[bot]' \
         STUB_STATUSES="$PURE" "$@"; }
sy
check "run: a pure, approved sync merges"                        grep -qx 'merge=true' "$WORK/out"
sy STUB_AUTHORS='app[bot] github-actions[bot]'
check "run: a sync allows the App alone as a commit author"      grep -qxF 'reason=a commit is by an author this policy does not merge: github-actions[bot]' "$WORK/out"
sy STUB_STATUSES='[{"context":"standards / verify","state":"success"},{"context":"standards / render","state":"failure"}]'
check "run: an agent-touched sync is held, and asks for a review" bash -c 'grep -qx merge=false "$1" && grep -qx review-wanted=true "$1"' _ "$WORK/out"

run '["backmerge:regenerated"]' '' success success '' POLICY=backmerge HEAD_REF=chore/backmerge-v1.2.3
check "run: an approved regenerated back-merge merges"           grep -qx 'merge=true' "$WORK/out"
run '["backmerge:regenerated"]' '' success '' '' POLICY=backmerge HEAD_REF=chore/backmerge-v1.2.3
check "run: an unreviewed one is held, and asks for a review"    bash -c 'grep -qx merge=false "$1" && grep -qx review-wanted=true "$1"' _ "$WORK/out"

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
