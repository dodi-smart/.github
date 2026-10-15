#!/usr/bin/env bash
# Assert what deps-verify's fix commits depend on: run-agent forwards the git
# identity it is given, and the push and publish steps behave as documented once
# claude-code-action has replaced the identity the job configured.
#
# The steps are lifted out of the workflow and run for real, in throwaway git
# repos, so the test reads the same script production runs. `gh` is a stub that
# records its calls. The push is never reached: with no App token the step
# refuses after it has written the commit, which is the part asserted here.
#
# The bot emails are single-quoted on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-agent-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# 1. run-agent forwards the identity, and defaults to the action's own.
identity_wired() {
python3 - "$ROOT" <<'EOF'
import sys, yaml
root = sys.argv[1]
doc = yaml.safe_load(open(root + '/actions/run-agent/action.yml'))
ins = doc['inputs']
assert ins['bot-name']['default'] == 'claude[bot]', ins['bot-name']
assert ins['bot-id']['default'] == '41898282', ins['bot-id']
call = [s for s in doc['runs']['steps'] if 'claude-code-action@' in str(s.get('uses', ''))][0]['with']
assert call['bot_name'] == '${{ inputs.bot-name }}', call.get('bot_name')
assert call['bot_id'] == '${{ inputs.bot-id }}', call.get('bot_id')
wf = yaml.safe_load(open(root + '/.github/workflows/deps-verify.yml'))['jobs']['verify']
agent = [s for s in wf['steps'] if 'run-agent@' in str(s.get('uses', ''))][0]['with']
assert agent['bot-name'] == '${{ env.FIX_NAME }}', agent.get('bot-name')
assert agent['bot-id'] == '${{ env.FIX_ID }}', agent.get('bot-id')
env = wf['env']
assert env['FIX_EMAIL'] == '%s+%s@users.noreply.github.com' % (env['FIX_ID'], env['FIX_NAME']), env
EOF
}
expect "run-agent forwards bot-name and bot-id, defaulting to claude-code-action's own" identity_wired

# claude-code-action names a tag-mode branch claude/issue-<n>-<ts> unless given a
# prefix, so run-agent always forwards one, and its default is conventional.
prefix_wired() {
python3 - "$ROOT" <<'EOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1] + '/actions/run-agent/action.yml'))
default = doc['inputs']['branch-prefix']['default']
assert default.endswith('/') and not default.startswith('claude'), default
call = [s for s in doc['runs']['steps'] if 'claude-code-action@' in str(s.get('uses', ''))][0]['with']
assert call['branch_prefix'] == '${{ inputs.branch-prefix }}', call.get('branch_prefix')
EOF
}
expect "run-agent forwards branch-prefix, defaulting to a conventional one, never claude/" prefix_wired

# 2. Lift the push and publish steps out of the workflow.
python3 - "$ROOT" "$WORK" <<'EOF' || { echo 'cannot read the deps-verify steps'; exit 1; }
import sys, yaml
root, work = sys.argv[1:3]
job = yaml.safe_load(open(root + '/.github/workflows/deps-verify.yml'))['jobs']['verify']
steps = {s.get('id'): s for s in job['steps'] if s.get('id')}
fix = job['env']
# The only expression the allowlist uses; everything else the step reads is a variable.
emails = steps['push']['env']['AGENT_EMAILS'].replace('${{ env.FIX_EMAIL }}', fix['FIX_EMAIL'])
open(work + '/push.sh', 'w').write(steps['push']['run'])
open(work + '/publish.sh', 'w').write(steps['publish']['run'])
open(work + '/actor.sh', 'w').write(steps['actor']['run'])
open(work + '/renovate.sh', 'w').write(steps['renovate']['run'])
open(work + '/fix.env', 'w').write('FIX_NAME=%r\nFIX_EMAIL=%r\n' % (fix['FIX_NAME'], fix['FIX_EMAIL']))
open(work + '/agent-emails', 'w').write(emails)
EOF
# shellcheck disable=SC1091
. "$WORK/fix.env"
AGENT_EMAILS="$(cat "$WORK/agent-emails")"
CLAUDE_EMAIL='41898282+claude[bot]@users.noreply.github.com'
expect "the allowlist holds the fix identity and claude[bot], and nothing else" \
  test "$(printf '%s\n' "$AGENT_EMAILS" | sort | tr '\n' ' ')" = "$(printf '%s\n%s\n' "$CLAUDE_EMAIL" "$FIX_EMAIL" | sort | tr '\n' ' ')"
expect "the push step writes the round with an explicit --author" \
  grep -qF -- '--author="$FIX_NAME <$FIX_EMAIL>"' "$WORK/push.sh"
expect "the push step sets the committer too" \
  grep -qE 'GIT_COMMITTER_NAME="\$FIX_NAME" GIT_COMMITTER_EMAIL="\$FIX_EMAIL"' "$WORK/push.sh"

# A repo with Renovate's commit on a branch, as the step finds it after checkout.
# Sets BASE (the head before the agent) and leaves the work tree on the branch.
repo() {
  local r="$WORK/r"
  rm -rf "$r" "$WORK/origin.git"
  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$r" 2>/dev/null
  git -C "$r" config user.name t; git -C "$r" config user.email t@example.com
  git -C "$r" commit -q --allow-empty -m init
  git -C "$r" push -q origin main
  git -C "$r" checkout -q -b renovate/x
  echo '{"x":"2"}' > "$r/package.json"
  git -C "$r" add -A
  git -C "$r" -c user.name=renovate -c user.email=renovate@example.com commit -q -m 'chore(deps): bump x'
  BASE="$(git -C "$r" rev-parse HEAD)"
  # What claude-code-action leaves in the checkout: its own identity, over ours.
  git -C "$r" config user.name 'claude[bot]'
  git -C "$r" config user.email "$CLAUDE_EMAIL"
}

# agent_commit EMAIL FILE: a commit as the agent would leave it.
agent_commit() {
  mkdir -p "$(dirname "$WORK/r/$2")"
  echo "$RANDOM" > "$WORK/r/$2"
  git -C "$WORK/r" add -A
  git -C "$WORK/r" -c user.name=who -c "user.email=$1" commit -q -m "fix: adapt to x ($2)"
}

# push [ROUNDS]: runs the push step; leaves its outputs in $WORK/out.
# FIX_PUSH and FIX_PUSH_WHY stand in for the renovate step (default: allowed).
push() {
  : > "$WORK/out"
  ( cd "$WORK/r" && env -i PATH="$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      FIX_NAME="$FIX_NAME" FIX_EMAIL="$FIX_EMAIL" AGENT_EMAILS="$AGENT_EMAILS" \
      FIX_PUSH="${FIX_PUSH-true}" FIX_PUSH_WHY="${FIX_PUSH_WHY:-}" \
      BASE_SHA="$BASE" ROUNDS="${1:-0}" BASE_REF=main HEAD_REF=renovate/x REPO=o/r APP_TOKEN='' \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/push.sh" ) > "$WORK/log" 2>&1
}
head_field() { git -C "$WORK/r" log -1 --format="$1"; }
refused()    { grep -F "refused=" "$WORK/out" | sed 's/^refused=//'; }

# 3. The agent committed as claude[bot], the case the job was refusing.
repo; agent_commit "$CLAUDE_EMAIL" src/a.ts; agent_commit "$CLAUDE_EMAIL" src/b.ts
push
expect "claude[bot] commits are not refused for their author" bash -c '! grep -q "another author" "$1"' _ "$WORK/out"
expect "the round is one commit on the base" test "$(git -C "$WORK/r" rev-list --count "$BASE..HEAD")" = 1
expect "its author is the fix identity" test "$(head_field '%an <%ae>')" = "$FIX_NAME <$FIX_EMAIL>"
expect "its committer is the fix identity" test "$(head_field '%cn <%ce>')" = "$FIX_NAME <$FIX_EMAIL>"
expect "it carries the round trailer" grep -q 'Deps-Verify-Round: 1' <(git -C "$WORK/r" log -1 --format=%B)
expect "it keeps both fixes" test "$(git -C "$WORK/r" show --format= --name-only HEAD | sort | tr '\n' ' ')" = 'src/a.ts src/b.ts '
expect "with no App token it stops after the commit, before any push" test "$(refused)" = 'GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks'

# 4. The agent used the identity it was told to use.
repo; agent_commit "$FIX_EMAIL" src/a.ts
push
expect "fix-identity commits pass the guard" test "$(refused)" = 'GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks'
expect "and are still one commit by the fix identity" test "$(head_field '%ae')" = "$FIX_EMAIL"

# 5. Any other author is refused, and the history is left as it was.
repo; agent_commit 'person@example.com' src/a.ts
before="$(git -C "$WORK/r" rev-parse HEAD)"
push
expect "a person's commit is refused" test "$(refused)" = 'a commit carries another author: person@example.com'
expect "and nothing is rewritten" test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"

repo; agent_commit "$CLAUDE_EMAIL" src/a.ts; agent_commit 'renovate@example.com' src/b.ts
push
expect "one stranger among agent commits refuses the round" test "$(refused)" = 'a commit carries another author: renovate@example.com'

# 6. The other guards are unchanged.
repo; agent_commit "$CLAUDE_EMAIL" src/a.ts
push 2
expect "the round cap still refuses" test "$(refused)" = 'fix-round cap of 2 reached'

repo; agent_commit "$CLAUDE_EMAIL" package.json
push
expect "a file Renovate changed is still refused" grep -q 'versions Renovate owns: package.json' "$WORK/out"

repo; agent_commit "$CLAUDE_EMAIL" yarn.lock
push
expect "a lockfile is still refused" grep -q 'versions Renovate owns: yarn.lock' "$WORK/out"

# 6b. The Renovate guard is checked before anything is rewritten.
repo; agent_commit "$CLAUDE_EMAIL" src/a.ts
before="$(git -C "$WORK/r" rev-parse HEAD)"
FIX_PUSH=false FIX_PUSH_WHY='Renovate does not ignore the fix author here' push
expect "a repo whose Renovate config does not ignore the fix author refuses the push" \
  test "$(refused)" = 'Renovate does not ignore the fix author here'
expect "and leaves the agent's commits as they were" test "$(git -C "$WORK/r" rev-parse HEAD)" = "$before"
repo; agent_commit "$CLAUDE_EMAIL" src/a.ts
FIX_PUSH='' push
expect "an unread Renovate config refuses rather than guesses" test "$(refused)" = 'the Renovate config was not read'

# 7. Publish. `gh` is a stub: it records the call and answers the events read.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
case "$*" in
  *"/events"*)  [ -n "${STUB_SETTER:-}" ] && echo "$STUB_SETTER" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gh"

# publish VERDICT AGENT_OUTCOME AGENT_CONCLUSION: no report files exist unless
# REPORT is set, so the fallback comment is built. STUB_SETTER names who last
# applied needs-manual.
publish() {
  : > "$WORK/calls"; : > "$WORK/out"; rm -f "$WORK/deps-verdict.json" "$WORK/deps-verdict.md"
  if [ -n "${REPORT:-}" ]; then
    echo "{\"verdict\": \"$REPORT\", \"reason\": \"r\"}" > "$WORK/deps-verdict.json"; echo body > "$WORK/deps-verdict.md"
  fi
  ( cd "$WORK" && env -i PATH="$WORK/bin:$PATH" HOME="$WORK" GH_TOKEN=t STUB_CALLS="$WORK/calls" \
      STUB_SETTER="${STUB_SETTER:-}" PR_AUTHOR='renovate[bot]' \
      REPO=o/r PR=7 VERDICT="$1" INTENT='' ROUNDS=0 REFUSED='' AGENT_OUTCOME="$2" AGENT_CONCLUSION="$3" \
      JSON="$WORK/deps-verdict.json" MD="$WORK/deps-verdict.md" COMMENT="$WORK/comment.md" APP_TOKEN='' \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/publish.sh" ) > "$WORK/log" 2>&1
}
removed() { grep -qF -- "-X DELETE /repos/o/r/issues/7/labels/$1" "$WORK/calls"; }

# A green, verified run is the case where needs-manual would be removed.
REPORT=verified STUB_SETTER='renovate[bot]' publish green success success
expect "a verified verdict is labelled verified" grep -qF 'labels[]=deps:verified' "$WORK/calls"
expect "a needs-manual label Renovate applied is kept" bash -c '! grep -qF -- "DELETE /repos/o/r/issues/7/labels/deps:needs-manual" "$1"' _ "$WORK/calls"
expect "and the other verdict labels are still cleared" removed deps:fixed

REPORT=verified STUB_SETTER='dodi-ci[bot]' publish green success success
expect "a needs-manual label this job applied is removed as before" removed deps:needs-manual

REPORT=verified STUB_SETTER='' publish green success success
expect "an unreadable event history is treated as this job's own label" removed deps:needs-manual

REPORT=verified STUB_SETTER='someone' publish green success success
expect "a label a person applied is not Renovate's, so it is removed" removed deps:needs-manual

REPORT=needs-manual STUB_SETTER='renovate[bot]' publish red:build success success
expect "the label history is not read when this job labels needs-manual itself" bash -c '! grep -qF /events "$1"' _ "$WORK/calls"

# 8. The no-report comment says something even when the build result is empty.
publish '' skipped ''
expect "an empty verdict is not printed as an empty code span" bash -c '! grep -qF "\`\`" "$1"' _ "$WORK/comment.md"
expect "it says no build result was recorded" grep -q 'No build result was recorded' "$WORK/comment.md"
expect "it says the agent did not run" grep -q 'The agent did not run' "$WORK/comment.md"
expect "the run still fails, so it is seen" grep -qx 'failed=true' "$WORK/out"

publish red:build success ''
expect "a known verdict is named in a code span" grep -qF 'Build: `red:build`' "$WORK/comment.md"
expect "an agent that skipped itself says so" grep -q 'skipped itself' "$WORK/comment.md"

publish green failure failure
expect "an agent that failed says so" grep -q 'The agent ran and failed' "$WORK/comment.md"

# 9. The actor step: the App that pushed a fix round may start the agent on it.
# actor ACTOR: runs the step in $WORK/r; prints its fix-pusher output.
actor() {
  : > "$WORK/out"
  ( cd "$WORK/r" && env -i PATH="$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      FIX_EMAIL="$FIX_EMAIL" ACTOR="$1" GITHUB_OUTPUT="$WORK/out" bash "$WORK/actor.sh" ) > "$WORK/log" 2>&1
  sed -n 's/^fix-pusher=//p' "$WORK/out"
}
# A fix round as the push step writes it, on top of Renovate's commit.
repo; agent_commit "$CLAUDE_EMAIL" src/a.ts; push
expect "a fix round's pusher is allowed when it is a bot" test "$(actor 'some-app[bot]')" = ',some-app[bot]'
expect "a person needs no allowance (the action checks people itself)" test "$(actor 'someone')" = ''
repo
expect "a bot that pushed anything but a fix round is not allowed" test "$(actor 'some-app[bot]')" = ''
repo; agent_commit "$FIX_EMAIL" src/a.ts
expect "the fix author without the round trailer is not a fix round" test "$(actor 'some-app[bot]')" = ''

# 10. The renovate step: which configs let a fix be pushed.
# renovate_cfg [FILE CONTENT]...: a checkout holding only these files.
renovate_cfg() {
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  while [ $# -gt 0 ]; do
    mkdir -p "$(dirname "$WORK/c/$1")"; printf '%s\n' "$2" > "$WORK/c/$1"; shift 2
  done
  : > "$WORK/out"
  ( cd "$WORK/c" && env -i PATH="$PATH" HOME="$WORK" FIX_EMAIL="$FIX_EMAIL" OWNER=o \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/renovate.sh" ) > "$WORK/log" 2>&1
}
fix_push() { sed -n 's/^fix-push=//p' "$WORK/out"; }
renovate_cfg
expect "a repo with no Renovate config may push" test "$(fix_push)" = true
renovate_cfg renovate.json "{\"gitIgnoredAuthors\": [\"$FIX_EMAIL\"]}"
expect "gitIgnoredAuthors naming the fix author may push" test "$(fix_push)" = true
renovate_cfg .github/renovate.json5 "{ extends: ['github>o/.github'] }"
expect "extending the shared preset may push" test "$(fix_push)" = true
renovate_cfg .github/renovate.json5 '{ "extends": ["config:recommended", "github>o/.github#v1"] }'
expect "extending the preset at a tag may push" test "$(fix_push)" = true
renovate_cfg renovate.json '{"extends": ["config:recommended"]}'
expect "a config that ignores nobody may not push" test "$(fix_push)" = false
expect "and says which file to change" grep -qF 'gitIgnoredAuthors in renovate.json' "$WORK/out"
renovate_cfg renovate.json '{"extends": ["github>o/.github:other"]}'
expect "another preset of this repo is not the default one" test "$(fix_push)" = false
renovate_cfg renovate.json '{"extends": ["github>elsewhere/.github"]}'
expect "another org's preset does not count" test "$(fix_push)" = false
renovate_cfg renovate.json '{}' .github/renovate.json "{\"gitIgnoredAuthors\": [\"$FIX_EMAIL\"]}"
expect "the first config in Renovate's search order is the one read" test "$(fix_push)" = false
renovate_cfg package.json "{\"name\": \"x\", \"renovate\": {\"gitIgnoredAuthors\": [\"$FIX_EMAIL\"]}}"
expect "a renovate key in package.json is read" test "$(fix_push)" = true
renovate_cfg package.json '{"name": "x"}'
expect "a package.json without a renovate key is no config" test "$(fix_push)" = true

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
