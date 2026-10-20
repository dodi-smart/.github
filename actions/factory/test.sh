#!/usr/bin/env bash
# Assert the factory's deterministic steps: the autonomy ladder, branch names,
# the guarded push, and the fix loop's next step. `gh` is a stub that answers
# from files, and the push runs in throwaway git repos.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$HERE/factory.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
val() { sed -n "s/^$1=//p" "$WORK/out" | tail -n 1; }

# 1. The ladder. Unset and unknown values are always draft.
tier() { : > "$WORK/out"; GITHUB_OUTPUT="$WORK/out" bash "$F" tier "$@" >/dev/null; val tier; }
expect "Autonomous Low/Low merges"            test "$(tier Autonomous Low Low)" = merge
expect "Autonomous Low/Medium is ready"       test "$(tier Autonomous Low Medium)" = ready
expect "Autonomous Medium/Low is ready"       test "$(tier Autonomous Medium Low)" = ready
expect "Autonomous Medium/Medium is ready"    test "$(tier Autonomous Medium Medium)" = ready
expect "Autonomous High risk is draft"        test "$(tier Autonomous High Low)" = draft
expect "Autonomous Critical risk is draft"    test "$(tier Autonomous Critical Low)" = draft
expect "Autonomous High effort is draft"      test "$(tier Autonomous Low High)" = draft
expect "Supervised Low/Low is draft"          test "$(tier Supervised Low Low)" = draft
expect "Human only is draft"                  test "$(tier 'Human only' Low Low)" = draft
expect "an unset risk is draft"               test "$(tier Autonomous '' Low)" = draft
expect "an unset mode is draft"               test "$(tier '' Low Low)" = draft

# 2. Branch names.
br() { : > "$WORK/out"; GITHUB_OUTPUT="$WORK/out" bash "$F" branch "$@" >/dev/null; val branch; }
expect "a bug is fix/<n>-<slug>"              test "$(br Bug 12 'Login fails on Safari!')" = fix/12-login-fails-on-safari
expect "a feature is feat/"                   test "$(br Feature 7 'Add CSV export')" = feat/7-add-csv-export
expect "an improvement is feat/"              test "$(br Improvement 7 'x')" = feat/7-x
expect "no type is chore/"                    test "$(br '' 3 'Tidy')" = chore/3-tidy
expect "never claude/"                        bash -c '! printf %s "$1" | grep -q ^claude' _ "$(br Task 1 a)"
expect "the slug is cut at 40 chars, with no trailing dash" \
  test "$(br Bug 1 'aaaaaaaaaa bbbbbbbbbb cccccccccc dddddd eeeeeeeeee')" = fix/1-aaaaaaaaaa-bbbbbbbbbb-cccccccccc-dddddd
expect "a title with nothing usable still names a branch" test "$(br Bug 9 '!!!')" = fix/9-issue

# 3. Push. A bare origin, a branch, and the agent's commits on top.
AGENT='41898282+claude[bot]@users.noreply.github.com'
repo() {   # repo ROUND-0-HOLDOUT? -> leaves $WORK/r on branch feat/1-x, BASE set
  rm -rf "$WORK/r" "$WORK/origin.git"
  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/r" 2>/dev/null
  git -C "$WORK/r" config user.name t; git -C "$WORK/r" config user.email t@example.com
  git -C "$WORK/r" commit -q --allow-empty -m init
  git -C "$WORK/r" push -q origin main
  git -C "$WORK/r" checkout -q -b feat/1-x
  BASE="$(git -C "$WORK/r" rev-parse HEAD)"
}
commit() {  # commit EMAIL FILE [SUBJECT] [TRAILERS]: TRAILERS is a paragraph of its own
  mkdir -p "$(dirname "$WORK/r/$2")"; echo "$RANDOM" >> "$WORK/r/$2"
  git -C "$WORK/r" add -A
  git -C "$WORK/r" -c user.name=a -c "user.email=$1" commit -q -m "${3:-wip $2}" ${4:+-m "$4"}
}
push() {   # push ROUND [SUBJECT]
  : > "$WORK/out"
  ( cd "$WORK/r" && env -i PATH="$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      BASE_SHA="$BASE" ROUND="$1" MAX_ROUNDS=3 HEAD_REF=feat/1-x REPO=o/r APP_TOKEN='' ISSUE=1 \
      SUBJECT="${2:-}" AGENT_EMAILS='' GITHUB_OUTPUT="$WORK/out" bash "$F" push ) > "$WORK/log" 2>&1
}
msg() { git -C "$WORK/r" log -1 --format=%B; }

repo; commit "$AGENT" src/a.ts; commit "$AGENT" test/a.test.ts
mkdir -p "$WORK/r/.factory/holdout.d"; printf 'test/a.test.ts\n' > "$WORK/r/.factory/holdout.d/1"
git -C "$WORK/r" add -A; git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'list holdout'
push 0 'feat(export): add csv export'
expect "round 0 is one commit"                test "$(git -C "$WORK/r" rev-list --count "$BASE..HEAD")" = 1
expect "with the validated subject"           test "$(git -C "$WORK/r" log -1 --format=%s)" = 'feat(export): add csv export'
expect "and the round and issue trailers"     bash -c 'grep -q "^Factory-Round: 0$" <<<"$1" && grep -q "^Factory-Issue: 1$" <<<"$1"' _ "$(msg)"
expect "authored as the factory identity"     test "$(git -C "$WORK/r" log -1 --format='%an <%ae>')" = "claude[bot] <$AGENT>"
expect "round 0 may write the holdout"        bash -c '! grep -q "holdout" "$1"' _ "$WORK/out"
expect "with no App token it stops before any push" test "$(val refused)" = 'GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks'

# The agent's own trailers survive the squash, after the round's; the ones the
# loop counts do not.
trailers() { git -C "$WORK/r" log -1 --format='%(trailers:only,unfold)' | sed '/^$/d'; }
repo
commit "$AGENT" src/a.ts 'feat: a' $'Decision: D-12\nCo-Authored-By: A <a@example.com>'
commit "$AGENT" src/b.ts 'feat: b' 'Decision: D-12'
push 0 'feat: ab'
expect "a trailer the agent wrote is kept after the round's, once though two commits carried it" \
  test "$(trailers)" = $'Factory-Round: 0\nFactory-Issue: 1\nDecision: D-12\nCo-Authored-By: A <a@example.com>'
expect "and git parses it as part of the one trailer block" \
  test "$(msg | git interpret-trailers --parse | grep -c '^Decision: D-12$')" = 1
repo
commit "$AGENT" src/a.ts 'feat: a' $'Factory-Round: 7\nFactory-Issue: 99\nDecision: D-3'
commit "$AGENT" src/b.ts 'feat: b' $'factory-round : 8\nDecision: D-4'
push 0 'feat: ab'
expect "a forged round or issue trailer is dropped" \
  test "$(trailers)" = $'Factory-Round: 0\nFactory-Issue: 1\nDecision: D-3\nDecision: D-4'
expect "and no forged value is anywhere in the message" \
  bash -c '! grep -qE "Factory-Round: 7|99|round : 8" <<<"$1"' _ "$(msg)"

repo; commit "$AGENT" src/a.ts 'not conventional'
push 0 'Add the thing'
expect "a subject that is not conventional falls back to the agent's" test "$(git -C "$WORK/r" log -1 --format=%s)" = 'not conventional'

repo; commit 'person@example.com' src/a.ts
push 0 'feat: x'
expect "a person's commit is refused"         test "$(val refused)" = 'a commit carries another author: person@example.com'

repo
push 0 'feat: x'
expect "no commits is no push"                test "$(val refused)" = 'the agent committed nothing'

# Fix rounds go through actions/push-round. `holdout` turns the issue's list as
# round 0 wrote it into push-round's refuse-paths, and push-round's own check
# refuses. ISSUE is the PR's issue; the list is .factory/holdout.d/<issue>.
holdout_repo() {
  repo
  mkdir -p "$WORK/r/.factory/holdout.d" "$WORK/r/test"
  printf '# holdout\ntest/a.test.ts\ntest/b(1).test.ts\n' > "$WORK/r/.factory/holdout.d/1"
  echo t > "$WORK/r/test/a.test.ts"; echo t > "$WORK/r/test/b(1).test.ts"
  git -C "$WORK/r" add -A; git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'feat: x'
  BASE="$(git -C "$WORK/r" rev-parse HEAD)"
}
ROUND_SH="$HERE/../push-round/round.sh"
round() {  # round [ISSUE] -> refused (empty when the round is ready); ISSUE defaults to 1
  : > "$WORK/out"
  paths=$(cd "$WORK/r" && BASE_SHA="$BASE" ISSUE="${1-1}" GITHUB_OUTPUT=/dev/null bash "$F" holdout | sed -n 's/^refuse-paths=//p')
  ( cd "$WORK/r" && env -i PATH="$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      BASE_SHA="$BASE" ROUNDS=0 MAX_ROUNDS=3 ALLOWED=true AGENT_EMAILS="$AGENT" \
      AUTHOR_NAME='claude[bot]' AUTHOR_EMAIL="$AGENT" REFUSE_PATHS="$paths" \
      GITHUB_OUTPUT="$WORK/out" bash "$ROUND_SH" check ) > "$WORK/log" 2>&1
  val refused
}
holdout_repo; commit "$AGENT" src/a.ts 'fix: make the test pass'
expect "a fix round that leaves the holdout alone is ready" test -z "$(round)"
expect "and push-round says so"               grep -qx 'ready=true' "$WORK/out"
holdout_repo; commit "$AGENT" test/a.test.ts 'fix: relax the test'
expect "a fix round that edits a holdout test is refused" grep -q 'test/a.test.ts' <<<"$(round)"
holdout_repo; git -C "$WORK/r" rm -q 'test/b(1).test.ts'; git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'fix: drop it'
expect "deleting a holdout test is refused, with ( ) read literally" grep -qF 'test/b(1).test.ts' <<<"$(round)"
holdout_repo; commit "$AGENT" .factory/holdout.d/1 'fix: shorter list'
expect "editing the holdout list is refused"  grep -q '.factory/holdout.d/1' <<<"$(round)"
holdout_repo; commit "$AGENT" test/a.test.tsx 'fix: a sibling'
expect "a file that only starts like a holdout path is not refused" test -z "$(round)"
repo; commit "$AGENT" src/a.ts
expect "with no holdout list only the list itself is guarded" test -z "$(round)"

# One list per issue: another issue's list, and the tests it names, are not this
# PR's to keep. They sit in the same tree once its PR has merged.
holdout_repo
printf 'test/c.test.ts\n' > "$WORK/r/.factory/holdout.d/2"; echo t > "$WORK/r/test/c.test.ts"
git -C "$WORK/r" add -A; git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'feat: y'
BASE="$(git -C "$WORK/r" rev-parse HEAD)"
commit "$AGENT" test/c.test.ts 'fix: another issue test'
expect "another issue's holdout test is not guarded"       test -z "$(round)"
commit "$AGENT" .factory/holdout.d/2 'fix: another issue list'
expect "nor is another issue's list"                       test -z "$(round)"
expect "but it is that issue's own"                        grep -q 'test/c.test.ts' <<<"$(round 2)"

# A PR opened before the lists moved has no holdout.d/<issue>. Its round 0 added
# its entries to the shared .factory/holdout, which also holds older PRs'.
legacy_repo() {  # legacy_repo ROUND0-ISSUE
  repo
  mkdir -p "$WORK/r/.factory" "$WORK/r/test"
  printf 'test/old.test.ts\n' > "$WORK/r/.factory/holdout"; echo t > "$WORK/r/test/old.test.ts"
  git -C "$WORK/r" add -A; git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'feat: older'
  printf '# mine\ntest/a.test.ts\n' >> "$WORK/r/.factory/holdout"; echo t > "$WORK/r/test/a.test.ts"
  git -C "$WORK/r" add -A
  git -C "$WORK/r" -c user.name=a -c "user.email=$AGENT" commit -q -m 'feat: x' -m "Factory-Round: 0
Factory-Issue: $1"
  BASE="$(git -C "$WORK/r" rev-parse HEAD)"
}
legacy_repo 1; commit "$AGENT" test/a.test.ts 'fix: relax'
expect "legacy: an entry this PR's round 0 added is guarded"  grep -q 'test/a.test.ts' <<<"$(round)"
legacy_repo 1; commit "$AGENT" test/old.test.ts 'fix: relax'
expect "legacy: an older PR's entry is not"                   test -z "$(round)"
legacy_repo 1; commit "$AGENT" .factory/holdout 'fix: shorter list'
expect "legacy: the old list itself is guarded"               grep -q '.factory/holdout' <<<"$(round)"
legacy_repo 12; commit "$AGENT" test/a.test.ts 'fix: relax'
expect "legacy: another issue's round 0 does not match (1 vs 12)" test -z "$(round)"
legacy_repo 12; commit "$AGENT" .factory/holdout 'fix: shorter list'
expect "legacy: with no round 0 of its own only the old list is guarded" grep -q '.factory/holdout' <<<"$(round)"
legacy_repo 12; commit "$AGENT" test/a.test.ts 'fix: relax'
expect "legacy: issue 12 does guard its own entry"            grep -q 'test/a.test.ts' <<<"$(round 12)"

# A merge round may not hand-resolve a lockfile either.
holdout_repo
mrp=$(cd "$WORK/r" && BASE_SHA="$BASE" ISSUE=1 GITHUB_OUTPUT=/dev/null bash "$F" holdout | sed -n 's/^merge-refuse-paths=//p')
expect "merge-refuse-paths holds the holdout test"    grep -qE "$mrp" <<<"test/a.test.ts"
expect "and a lockfile, in any directory"             bash -c 'grep -qE "$1" <<<"package-lock.json" && grep -qE "$1" <<<"app/bun.lock"' _ "$mrp"
expect "but not ordinary source"                      bash -c '! grep -qE "$1" <<<"src/a.ts"' _ "$mrp"

# A PR a person labelled has no issue and no list to find.
holdout_repo; commit "$AGENT" test/a.test.ts 'fix: relax'
expect "with no issue the list's tests are not guarded"       test -z "$(round '')"
holdout_repo; commit "$AGENT" .factory/holdout 'fix: write the old list'
expect "with no issue the old list is guarded"                grep -q '.factory/holdout' <<<"$(round '')"

# 4. decide. The stub answers each API path from a file under $WORK/api.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh api [flags] PATH [--jq EXPR]: print the canned body for PATH through jq.
path=''; jqx='.'
while [ $# -gt 0 ]; do
  case "$1" in
    api) ;;
    --jq) jqx="$2"; shift ;;
    -f|-F) [ "${2%%=*}" = n ] && path="graphql-issue"; shift ;;
    --paginate) ;;
    graphql) path=graphql ;;
    *) [ -z "$path" ] && path="$1" ;;
  esac
  shift
done
[ "$path" = graphql ] && path=graphql-issue
key=$(printf '%s' "${path%%\?*}" | tr '/' '_')
f="$STUB_API/$key"
# A path with numbered answers (file.1, file.2, ...) answers them in order and
# then repeats the last: GitHub's mergeable state changes between two reads.
if [ -f "$f.1" ]; then
  n=$(( $(cat "$f.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f.n"
  while [ ! -f "$f.$n" ]; do n=$((n - 1)); done
  f="$f.$n"
fi
[ -f "$f" ] || exit 1
jq -r "$jqx" "$f"
EOF
chmod +x "$WORK/bin/gh"
# `sleep` only records, so a test can count the waits.
printf '#!/usr/bin/env bash\necho "$*" >> "${WORK_SLEEPS:-/dev/null}"\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/sleep"

# scenario TIER-FIELDS CHECKS VERDICT [DRAFT] [LABELS] [ROUNDS]; MSTATE sets mergeable_state
api() { mkdir -p "$WORK/api"; printf '%s' "$2" > "$WORK/api/$(printf '%s' "$1" | tr '/' '_')"; }
scenario() {
  rm -rf "$WORK/api"
  local mode="$1" checks="$2" verdict="$3" draft="${4:-false}" labels="${5:-[\"agent:iterate\"]}" rounds="${6:-0}"
  api /repos/o/r/pulls/5 "{\"state\":\"open\",\"draft\":$draft,\"labels\":$(jq -c '[.[]|{name:.}]' <<<"$labels"),
    \"head\":{\"sha\":\"abc\",\"ref\":\"feat/1-x\",\"repo\":{\"full_name\":\"o/r\"}},
    \"base\":{\"ref\":\"main\",\"repo\":{\"full_name\":\"o/r\"}},\"body\":\"text\n\nCloses #1\",
    \"mergeable_state\":\"${MSTATE:-clean}\",\"user\":{\"login\":\"${AUTHOR:-dodi-smart-github-assistant[bot]}\"}}"
  api /repos/o/r/issues/1/labels '[]'
  local m r e; read -r m r e <<<"$mode"
  api graphql-issue "{\"data\":{\"repository\":{\"issue\":{\"issueFieldValues\":{\"nodes\":[
    {\"name\":\"$m\",\"field\":{\"name\":\"Agent mode\"}},{\"name\":\"$r\",\"field\":{\"name\":\"Risk\"}},
    {\"name\":\"$e\",\"field\":{\"name\":\"Effort\"}},{\"name\":\"Plan ready\",\"field\":{\"name\":\"Triage state\"}},
    {\"name\":\"Medium\",\"field\":{\"name\":\"Priority\"}}]}}}}}"
  local msgs='[{"commit":{"message":"feat: x\n\nFactory-Round: 0"}}'
  for ((i = 1; i <= rounds; i++)); do msgs="$msgs,{\"commit\":{\"message\":\"fix: y\n\nFactory-Round: $i\"}}"; done
  api /repos/o/r/pulls/5/commits "$msgs]"
  if [ -n "$checks" ]; then
    api /repos/o/r/commits/abc/check-runs "{\"check_runs\":[{\"name\":\"checks / PR Checks\",\"status\":\"${checks%% *}\",\"conclusion\":\"${checks#* }\",\"started_at\":\"1\",\"details_url\":\"https://x/o/r/actions/runs/77/job/1\"}]}"
  else
    api /repos/o/r/commits/abc/check-runs '{"check_runs":[]}'
  fi
  if [ -n "$verdict" ]; then
    api /repos/o/r/commits/abc/statuses "[{\"context\":\"review / verdict\",\"state\":\"$verdict\"}]"
  else
    api /repos/o/r/commits/abc/statuses '[]'
  fi
}
decide() {  # decide [EVENT_SHA] -> action
  : > "$WORK/out"
  env -i PATH="$WORK/bin:$PATH" HOME="$WORK" STUB_API="$WORK/api" REPO=o/r PR=5 EVENT_SHA="${1:-}" \
    MAX_ROUNDS=3 MERGEABLE_WAIT=0 GITHUB_OUTPUT="$WORK/out" bash "$F" decide > "$WORK/log" 2>&1
  val action
}

AUTHOR='renovate[bot]' scenario 'Autonomous Low Low' 'completed failure' ''
expect "a Renovate PR with agent:iterate stops" test "$(decide)" = stop
expect "and says deps-verify owns it"         grep -q 'dependency-bot PR' "$WORK/out"
AUTHOR='dependabot[bot]' scenario 'Autonomous Low Low' 'completed success' 'success'
expect "a green, approved Dependabot PR is not landed" test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed failure' ''
expect "red checks start a fix round"         test "$(decide)" = fix-ci
expect "and the failed run is named"          test "$(val run-id)" = 77
expect "and the fields the model policy reads are out" bash -c 'grep -qx "risk=Low" "$1" && grep -qx "effort=Low" "$1" && grep -qx "priority=Medium" "$1"' _ "$WORK/out"
expect "a run with no jobs to read is not lint-only" test -z "$(val signals)"
jobs() { api /repos/o/r/actions/runs/77/jobs "{\"jobs\":$1}"; }
hk='{"name":"hk check --all","conclusion":"failure"}'
agg='{"name":"checks / PR Checks","conclusion":"failure","steps":[{"name":"Fail when a job failed","conclusion":"failure"}]}'
jobs "[{\"name\":\"checks / checks\",\"conclusion\":\"failure\",\"steps\":[$hk]},$agg]"
decide >/dev/null
expect "only hk failed, beside the aggregate job: lint-only" test "$(val signals)" = lint-only
jobs "[{\"name\":\"checks / checks\",\"conclusion\":\"failure\",\"steps\":[$hk]},{\"name\":\"checks / test\",\"conclusion\":\"failure\",\"steps\":[{\"name\":\"Run phases\",\"conclusion\":\"failure\"}]},$agg]"
decide >/dev/null
expect "hk and tests failed: not lint-only"   test -z "$(val signals)"
jobs "[{\"name\":\"checks / build\",\"conclusion\":\"failure\",\"steps\":[]},$agg]"
decide >/dev/null
expect "a job that failed with no failed step: not lint-only" test -z "$(val signals)"
scenario 'Autonomous Low Low' 'completed failure' '' false '["agent:iterate"]' 1
jobs "[{\"name\":\"checks / checks\",\"conclusion\":\"failure\",\"steps\":[$hk]},$agg]"
decide >/dev/null
expect "after a fix round lint is not checked: the next round is Opus anyway" test -z "$(val signals)"
scenario 'Autonomous Low Low' 'completed failure' '' false '["agent:iterate"]' 3
expect "red after 3 rounds gives up"          test "$(decide)" = give-up
scenario 'Autonomous Low Low' 'in_progress none' ''
expect "running checks wait"                  test "$(decide)" = stop
scenario 'Autonomous Low Low' '' ''
expect "no checks yet waits"                  test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' '' true
expect "a green draft at merge is marked ready" test "$(decide)" = ready
scenario 'Autonomous Low Low' '' '' true
expect "a draft PR Checks skipped is marked ready too" test "$(decide)" = ready
scenario 'Autonomous Low Low' 'completed failure' '' true
expect "a red draft is fixed before it is marked ready" test "$(decide)" = fix-ci
scenario 'Supervised Low Low' '' '' true
expect "a draft-tier draft is never marked ready" test "$(decide)" = stop
scenario 'Autonomous Medium Low' 'completed success' '' true
expect "a green draft at ready is marked ready" test "$(decide)" = ready
scenario 'Supervised Low Low' 'completed success' '' true
expect "a green draft at draft tier stays a draft" test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' '' false '["agent:iterate"]' 1
expect "a fix round with no verdict asks for review" test "$(decide)" = review
scenario 'Autonomous Low Low' 'completed success' '' false '["agent:iterate","agent:review"]' 1
expect "but only once"                        test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' ''
expect "round 0 with no verdict asks for review too: ready_for_review reviews no App PR" test "$(decide)" = review
scenario 'Autonomous Low Low' 'completed success' 'failure'
expect "a changes verdict starts a fix round" test "$(decide)" = fix-review
scenario 'Autonomous Low Low' 'completed success' 'failure' false '["agent:iterate"]' 3
expect "changes after 3 rounds gives up"      test "$(decide)" = give-up
scenario 'Autonomous Low Low' 'completed success' 'success'
expect "green and approved at merge lands"    test "$(decide)" = land
scenario 'Autonomous Medium Medium' 'completed success' 'success'
expect "green and approved at ready is done"  test "$(decide)" = handoff
scenario 'Supervised Low Low' 'completed success' 'success'
expect "green and approved at draft tier is done, never land" test "$(decide)" = handoff
scenario 'Autonomous Low Low' 'completed success' 'success' false '["agent:iterate","agent:no-touch"]'
expect "agent:no-touch on the PR stops everything" test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' 'success'
api /repos/o/r/issues/1/labels '[{"name":"agent:no-touch"}]'
expect "agent:no-touch on the issue stops everything" test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' 'success' false '[]'
expect "no agent:iterate, no loop"            test "$(decide)" = stop
scenario 'Autonomous Low Low' 'completed success' 'success'
expect "an event for an older commit stops"   test "$(decide old)" = stop
scenario 'Autonomous Low Low' 'completed success' 'success'
rm "$WORK/api/graphql-issue"
expect "unreadable fields are draft, never land" test "$(decide)" = handoff

# A conflicted PR is judged before its checks. Only `dirty` is a conflict;
# everything else merges and is left alone.
MSTATE=dirty scenario 'Autonomous Low Low' '' ''
expect "a conflicted PR is updated, though no checks ran" test "$(decide)" = update
expect "and the state is out"                 test "$(val mergeable-state)" = dirty
# Checks, draft and tier change nothing: the conflict is judged before them.
for c in 'red checks|Autonomous Low Low|completed failure|false' 'a draft|Autonomous Low Low||true' 'a supervised tier|Supervised Low Low||false'; do
  IFS='|' read -r name tier checks draft <<<"$c"
  MSTATE=dirty scenario "$tier" "$checks" '' "$draft"
  expect "a conflicted PR is updated first: $name" test "$(decide)" = update
done
MSTATE=dirty scenario 'Autonomous Low Low' '' '' false '["agent:iterate"]' 2
expect "a merge round counts: two rounds of three still update" test "$(decide)" = update
MSTATE=dirty scenario 'Autonomous Low Low' '' '' false '["agent:iterate"]' 3
expect "a conflict at the round cap gives up" test "$(decide)" = give-up
expect "and says why"                         grep -q 'conflicts with its base after 3 fix rounds' "$WORK/out"
MSTATE=dirty scenario 'Autonomous Low Low' '' '' false '["agent:iterate","agent:no-touch"]'
expect "agent:no-touch on a conflicted PR still stops" test "$(decide)" = stop
MSTATE=dirty scenario 'Autonomous Low Low' '' '' false '[]'
expect "a conflicted PR without agent:iterate is not touched" test "$(decide)" = stop
MSTATE=dirty scenario 'Autonomous Low Low' '' ''
api /repos/o/r/issues/1/labels '[{"name":"agent:no-touch"}]'
expect "agent:no-touch on the issue of a conflicted PR still stops" test "$(decide)" = stop
MSTATE=dirty AUTHOR='renovate[bot]' scenario 'Autonomous Low Low' '' ''
expect "a conflicted dependency-bot PR is not the loop's" test "$(decide)" = stop
MSTATE=dirty scenario 'Autonomous Low Low' '' ''
expect "an event for an older commit on a conflicted PR stops" test "$(decide old)" = stop
for st in clean behind unstable blocked; do
  MSTATE=$st scenario 'Autonomous Low Low' 'completed failure' ''
  expect "mergeable_state $st is no conflict: red checks still start a fix" test "$(decide)" = fix-ci
done
# A draft reads `draft` whether or not it conflicts; `mergeable` says which.
MSTATE=draft scenario 'Autonomous Low Low' '' '' true
jq '.mergeable = false' "$WORK/api/_repos_o_r_pulls_5" > "$WORK/api/x" && mv "$WORK/api/x" "$WORK/api/_repos_o_r_pulls_5"
expect "a draft GitHub cannot merge is a conflict, and is updated" test "$(decide)" = update
MSTATE=draft scenario 'Supervised Low Low' 'completed failure' '' true
jq '.mergeable = true' "$WORK/api/_repos_o_r_pulls_5" > "$WORK/api/x" && mv "$WORK/api/x" "$WORK/api/_repos_o_r_pulls_5"
expect "a draft that merges is no conflict"   test "$(decide)" = fix-ci
# GitHub answers `unknown` until it has computed the state: one re-read.
pr_seq() {  # pr_seq N STATE: the Nth answer to a read of the PR
  jq --arg s "$2" '.mergeable_state = $s' "$WORK/api/_repos_o_r_pulls_5" > "$WORK/api/_repos_o_r_pulls_5.$1"
}
MSTATE=unknown scenario 'Autonomous Low Low' 'completed failure' ''
pr_seq 1 unknown; pr_seq 2 dirty
expect "unknown, then dirty on the re-read, is updated" test "$(decide)" = update
MSTATE=unknown scenario 'Autonomous Low Low' 'completed failure' ''
pr_seq 1 unknown; pr_seq 2 unknown
expect "unknown twice is no conflict: the normal rules decide" test "$(decide)" = fix-ci
expect "and the state stays unknown"          test "$(val mergeable-state)" = unknown
MSTATE=unknown scenario 'Autonomous Low Low' 'completed failure' ''
pr_seq 1 unknown; pr_seq 2 clean
expect "unknown, then clean, is no conflict"  test "$(decide)" = fix-ci
MSTATE=dirty scenario 'Autonomous Low Low' 'completed success' 'success'
pr_seq 1 dirty; pr_seq 2 clean
expect "a settled state is read once: dirty is not re-read into clean" test "$(decide)" = update
scenario 'Autonomous Low Low' 'completed success' 'success'
jq 'del(.mergeable_state)' "$WORK/api/_repos_o_r_pulls_5" > "$WORK/api/x" && mv "$WORK/api/x" "$WORK/api/_repos_o_r_pulls_5"
expect "a PR with no mergeable_state at all is no conflict: green and approved lands" test "$(decide)" = land

# 5. fields: a failed read says so, so implement fails instead of refusing.
fields() {
  : > "$WORK/out"
  env -i PATH="$WORK/bin:$PATH" HOME="$WORK" STUB_API="$WORK/api" REPO=o/r ISSUE=1 \
    GITHUB_OUTPUT="$WORK/out" bash "$F" fields > "$WORK/log" 2>&1
}
scenario 'Autonomous Low Low' '' ''
fields
expect "fields reads the state and the tier" bash -c 'grep -qx "state=Plan ready" "$1" && grep -qx "tier=merge" "$1" && grep -qx "read=true" "$1"' _ "$WORK/out"
expect "and the priority" grep -qx "priority=Medium" "$WORK/out"
rm "$WORK/api/graphql-issue"
fields
expect "an unreadable issue says read=false and tier draft" bash -c 'grep -qx "read=false" "$1" && grep -qx "tier=draft" "$1"' _ "$WORK/out"

# 6. sweep: the open agent PRs that conflict. It lists; it edits nothing.
sweep_pr() {  # sweep_pr NUM STATE [LABEL...]: an open PR as the issues list and the PR read show it
  local n="$1" st="$2" l; shift 2
  l=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({name: .})')
  jq -c --argjson n "$n" --argjson l "$l" '. + [{number: $n, pull_request: {}, labels: $l}]' "$WORK/api/_repos_o_r_issues" > "$WORK/api/x" \
    && mv "$WORK/api/x" "$WORK/api/_repos_o_r_issues"
  api "/repos/o/r/pulls/$n" "{\"state\":\"open\",\"mergeable_state\":\"$st\",\"head\":{\"repo\":{\"full_name\":\"${FORK:-o/r}\"}},\"base\":{\"repo\":{\"full_name\":\"o/r\"}},\"user\":{\"login\":\"${AUTHOR:-claude[bot]}\"}}"
}
sweep() {
  : > "$WORK/out"; : > "$WORK/sleeps"; rm -f "$WORK"/api/*.n
  env -i PATH="$WORK/bin:$PATH" HOME="$WORK" STUB_API="$WORK/api" WORK_SLEEPS="$WORK/sleeps" REPO=o/r MERGEABLE_WAIT=0 \
    GITHUB_OUTPUT="$WORK/out" bash "$F" sweep > "$WORK/log" 2>&1
  val dirty
}
rm -rf "$WORK/api"; mkdir -p "$WORK/api"; echo '[]' > "$WORK/api/_repos_o_r_issues"
expect "no agent PRs: nothing dirty"          test -z "$(sweep)"
sweep_pr 11 dirty agent:iterate
sweep_pr 12 clean agent:iterate
sweep_pr 13 behind agent:iterate
sweep_pr 14 dirty agent:iterate agent:no-touch
FORK=someone/r sweep_pr 15 dirty agent:iterate
AUTHOR='renovate[bot]' sweep_pr 16 dirty agent:iterate
sweep_pr 17 dirty agent:iterate
jq -c '. + [{number: 19, labels: [{name: "agent:iterate"}]}]' "$WORK/api/_repos_o_r_issues" > "$WORK/api/x" \
  && mv "$WORK/api/x" "$WORK/api/_repos_o_r_issues"
api /repos/o/r/pulls/19 '{"state":"open","mergeable_state":"dirty","head":{"repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}},"user":{"login":"claude[bot]"}}'
expect "sweep lists the open, same-repo, conflicted agent PRs: not no-touch, a fork, a dependency bot or a plain issue" \
  test "$(sweep)" = '11 17'
# Two PRs GitHub had not judged: the first read starts it, one wait, then both are read again.
sweep_pr 18 unknown agent:iterate
sweep_pr 20 unknown agent:iterate
for n in 18 20; do jq '.mergeable_state = "unknown"' "$WORK/api/_repos_o_r_pulls_$n" > "$WORK/api/_repos_o_r_pulls_$n.1"; done
jq '.mergeable_state = "dirty"' "$WORK/api/_repos_o_r_pulls_18" > "$WORK/api/_repos_o_r_pulls_18.2"
jq '.mergeable_state = "clean"' "$WORK/api/_repos_o_r_pulls_20" > "$WORK/api/_repos_o_r_pulls_20.2"
expect "a PR GitHub had not judged yet is read again" test "$(sweep)" = '11 17 18'
expect "and all of them are waited for once" test "$(wc -l < "$WORK/sleeps" | tr -d ' ')" = 1

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
