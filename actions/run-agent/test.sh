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

# The model comes from pick-model, never from a literal or straight from inputs.
model_wired() {
python3 - "$ROOT" <<'EOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1] + '/actions/run-agent/action.yml'))
assert doc['inputs']['model']['default'] == '', doc['inputs']['model']
steps = doc['runs']['steps']
pick = [s for s in steps if s.get('id') == 'model'][0]
assert 'pick-model/pick.sh' in pick['run'], pick
assert steps.index(pick) == 0, 'the model step runs first'
call = [s for s in steps if 'claude-code-action@' in str(s.get('uses', ''))][0]['with']
assert '--model ${{ steps.model.outputs.model }}' in call['claude_args'], call['claude_args']
assert 'steps.model.outputs.max-turns' in call['claude_args'] and 'inputs.max-turns' not in call['claude_args'], call['claude_args']
EOF
}
expect "run-agent runs on the model and cap pick-model chose" model_wired

# The org's plugins and env reach the action, and the settings file is removed.
org_wired() {
python3 - "$ROOT" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1] + '/actions/run-agent/action.yml'))['runs']['steps']
call = [s for s in steps if 'claude-code-action@' in str(s.get('uses', ''))][0]['with']
assert call['plugins'] == '${{ steps.org.outputs.plugins }}', call['plugins']
assert call['plugin_marketplaces'] == '${{ steps.org.outputs.marketplaces }}', call['plugin_marketplaces']
assert call['settings'] == '${{ steps.org.outputs.settings }}', call.get('settings')
assert any('rm -f "$SETTINGS"' in str(s.get('run', '')) and 'always()' in str(s.get('if', '')) for s in steps), 'no cleanup'
EOF
}
expect "run-agent passes the org's plugins and the agent env, and removes the file after" org_wired

# 2. Lift the steps out of the workflow. The push itself is actions/push-round,
# tested there.
python3 - "$ROOT" "$WORK" <<'EOF' || { echo 'cannot read the deps-verify steps'; exit 1; }
import sys, yaml
root, work = sys.argv[1:3]
job = yaml.safe_load(open(root + '/.github/workflows/deps-verify.yml'))['jobs']['verify']
steps = {s.get('id'): s for s in job['steps'] if s.get('id')}
fix = job['env']
for sid in ('publish', 'actor', 'renovate'):
    open('%s/%s.sh' % (work, sid), 'w').write(steps[sid]['run'])
ra = {s.get('id'): s for s in yaml.safe_load(open(root + '/actions/run-agent/action.yml'))['runs']['steps']}
for sid in ('outcome', 'validate', 'report'):
    open('%s/%s.sh' % (work, sid), 'w').write(ra[sid]['run'])
open(work + '/fix.env', 'w').write('FIX_NAME=%r\nFIX_EMAIL=%r\n' % (fix['FIX_NAME'], fix['FIX_EMAIL']))
push = steps['push']['with']
assert push['author-email'] == '${{ env.FIX_EMAIL }}' and push['trailer-key'] == 'Deps-Verify-Round', push
assert 'deps-verify' not in push.get('refuse-paths', ''), push
EOF
# shellcheck disable=SC1091
. "$WORK/fix.env"

# A repo with Renovate's commit on a branch, for the actor step below.
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
}
# fix_round: a round as push-round writes it.
fix_round() {
  echo "$RANDOM" > "$WORK/r/a.ts"; git -C "$WORK/r" add -A
  git -C "$WORK/r" -c user.name="$FIX_NAME" -c user.email="$FIX_EMAIL" commit -q -m 'fix: adapt' -m 'Deps-Verify-Round: 1'
}

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

# publish VERDICT: no report files exist unless REPORT is set. STUB_SETTER
# names who last applied needs-manual.
publish() {
  : > "$WORK/calls"; : > "$WORK/out"; rm -f "$WORK/deps-verdict.json" "$WORK/deps-verdict.md"
  if [ -n "${REPORT:-}" ]; then
    echo "{\"verdict\": \"$REPORT\", \"reason\": \"r\"}" > "$WORK/deps-verdict.json"; echo body > "$WORK/deps-verdict.md"
  fi
  ( cd "$WORK" && env -i PATH="$WORK/bin:$PATH" HOME="$WORK" GH_TOKEN=t STUB_CALLS="$WORK/calls" \
      STUB_SETTER="${STUB_SETTER:-}" PR_AUTHOR='renovate[bot]' \
      REPO=o/r PR=7 VERDICT="$1" INTENT='' ROUNDS=0 REFUSED='' REPORT_SOURCE=agent AGENT_SKIPPED='' \
      JSON="$WORK/deps-verdict.json" MD="$WORK/deps-verdict.md" COMMENT="$WORK/comment.md" APP_TOKEN='' \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/publish.sh" ) > "$WORK/log" 2>&1
}
removed() { grep -qF -- "-X DELETE /repos/o/r/issues/7/labels/$1" "$WORK/calls"; }

# A green, verified run is the case where needs-manual would be removed.
REPORT=verified STUB_SETTER='renovate[bot]' publish green
expect "a verified verdict is labelled verified" grep -qF 'labels[]=deps:verified' "$WORK/calls"
expect "a needs-manual label Renovate applied is kept" bash -c '! grep -qF -- "DELETE /repos/o/r/issues/7/labels/deps:needs-manual" "$1"' _ "$WORK/calls"
expect "and the other verdict labels are still cleared" removed deps:fixed

REPORT=verified STUB_SETTER='dodi-ci[bot]' publish green
expect "a needs-manual label this job applied is removed as before" removed deps:needs-manual

REPORT=verified STUB_SETTER='' publish green
expect "an unreadable event history is treated as this job's own label" removed deps:needs-manual

REPORT=verified STUB_SETTER='someone' publish green
expect "a label a person applied is not Renovate's, so it is removed" removed deps:needs-manual

REPORT=needs-manual STUB_SETTER='renovate[bot]' publish red:build
expect "the label history is not read when this job labels needs-manual itself" bash -c '! grep -qF /events "$1"' _ "$WORK/calls"

# 8. run-agent's report step: the report file exists and is valid on every path.
# report [WHY]: the agent's file is REPORT (a verdict word, or raw JSON with RAW);
# WHY stands in for the outcome or validate step. Leaves the file in $WORK.
report() {
  : > "$WORK/out"; rm -f "$WORK/deps-verdict.json"
  [ -n "${REPORT:-}" ] && echo "{\"verdict\": \"$REPORT\", \"reason\": \"r\"}" > "$WORK/deps-verdict.json"
  [ -n "${RAW:-}" ] && printf '%s' "$RAW" > "$WORK/deps-verdict.json"
  ( cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" FILE="$WORK/deps-verdict.json" \
      VALID='.verdict | IN("verified", "fixed", "needs-manual")' FALLBACK='{"verdict": "needs-manual"}' \
      WHY="${1:-}" TURNS="${TURNS:-}" GITHUB_OUTPUT="$WORK/out" bash "$WORK/report.sh" ) > "$WORK/log" 2>&1
}
field() { jq -r ".$1" "$WORK/deps-verdict.json"; }

REPORT=verified report
expect "a valid report is the agent's" grep -qx 'source=agent' "$WORK/out"
expect "and is left as written" test "$(field reason)" = r
report 'The agent reached its turn cap after 41 turns.'
expect "a missing report becomes the fallback" test "$(field verdict)" = needs-manual
expect "with the reason as why" test "$(field why)" = 'The agent reached its turn cap after 41 turns.'
expect "and says it is the fallback" grep -qx 'source=fallback' "$WORK/out"
REPORT=bogus report
expect "an invalid verdict word is replaced" test "$(field verdict)" = needs-manual
RAW='not json' TURNS=12 report
expect "unreadable JSON is replaced, naming the turns" grep -q 'finished after 12 turn(s) without writing a valid deps-verdict.json' <(field why)

# 8b. Publish words what run-agent wrote, and fails only on a real failure.
printf '{"verdict":"needs-manual","why":"claude-code-action refuses to run while x.yml differs"}' > "$WORK/mismatch.json"
pub_fallback() {
  : > "$WORK/calls"; : > "$WORK/out"; rm -f "$WORK/deps-verdict.md"; cp "$WORK/mismatch.json" "$WORK/deps-verdict.json"
  ( cd "$WORK" && env -i PATH="$WORK/bin:$PATH" HOME="$WORK" GH_TOKEN=t STUB_CALLS="$WORK/calls" PR_AUTHOR='renovate[bot]' \
      REPO=o/r PR=7 VERDICT=green INTENT='' ROUNDS=0 REFUSED='' REPORT_SOURCE=fallback AGENT_SKIPPED="$1" \
      JSON="$WORK/deps-verdict.json" MD="$WORK/deps-verdict.md" COMMENT="$WORK/comment.md" APP_TOKEN='' \
      GITHUB_OUTPUT="$WORK/out" bash "$WORK/publish.sh" ) > "$WORK/log" 2>&1
}
pub_fallback workflow-mismatch
expect "the fallback's why is the comment's reason" grep -q 'refuses to run while x.yml' "$WORK/comment.md"
expect "with the build named, never an empty code span" grep -qF 'Build: `green`' "$WORK/comment.md"
expect "a deliberate skip does not fail the run" bash -c '! grep -q failed= "$1"' _ "$WORK/out"
pub_fallback ''
expect "any other fallback fails the run" grep -qx 'failed=true' "$WORK/out"
publish red:build
expect "no report at all is needs-manual" grep -qF 'labels[]=deps:needs-manual' "$WORK/calls"
expect "naming the step before the agent" grep -q 'step before the agent failed' "$WORK/comment.md"
expect "and fails the run" grep -qx 'failed=true' "$WORK/out"

# 8d. run-agent's outcome step reads what claude-code-action keeps out of the log.
# outcome OUTCOME [EXECUTION-FILE-JSON]: prints the step's outputs.
outcome() {
  : > "$WORK/out"; rm -f "$WORK/exe.json"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$WORK/exe.json"
  ( cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" RUNNER_TEMP="$WORK/none" OUTCOME="$1" \
      EXECUTION_FILE="${2:+$WORK/exe.json}" GITHUB_OUTPUT="$WORK/out" bash "$WORK/outcome.sh" ) > "$WORK/log" 2>&1
}
out_why() { sed -n 's/^why=//p' "$WORK/out"; }
outcome failure '[{"type":"system"},{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":41}]'
expect "the turn cap is named" test "$(out_why)" = 'The agent reached its turn cap after 41 turns.'
outcome failure '[{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"Invalid API key\nPlease run /login"}]'
expect "the hidden error text is read from the execution file" test "$(out_why)" = 'The agent stopped with an error after 1 turn(s): Invalid API key Please run /login.'
outcome success '[{"type":"result","subtype":"success","is_error":false,"num_turns":12,"result":"done"}]'
expect "a normal finish has no why" test -z "$(out_why)"
expect "and reports its turns" grep -qx 'turns=12' "$WORK/out"
outcome success '[{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.42,"result":""}]'
expect "the cost is read, an empty result text does not shift it" bash -c 'grep -qx "cost=0.42" "$1" && grep -qx "turns=3" "$1"' _ "$WORK/out"
expect "and one Agent run notice carries it" grep -q '::notice title=Agent run::.*turns=3 cost=0.42' "$WORK/log"
outcome failure '[{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"errors":[{"m":"x"}]}]'
expect "structured errors do not break the step" grep -q 'error after 2 turn(s)' <(out_why)
outcome success
expect "no result after a success is the action skipping itself" grep -q 'skipped itself' <(out_why)
outcome failure
expect "no result after a failure says the action failed first" grep -q 'failed before the agent produced a result' <(out_why)

# 8d2. agent-env.sh: the org's plugins on top of the caller's, and env for the agent alone.
# agent_env [ENV=value ...]: runs it, outputs in $WORK/out, log in $WORK/log.
agent_env() {
  : > "$WORK/out"; rm -rf "$WORK/rt"; mkdir -p "$WORK/rt"
  env -i PATH="$PATH" HOME="$WORK" RUNNER_TEMP="$WORK/rt" GITHUB_OUTPUT="$WORK/out" "$@" \
    bash "$ROOT/actions/run-agent/agent-env.sh" > "$WORK/log" 2>&1
}
multi_out() { sed -n "/^$1<<__AGENT_ENV_EOF__$/,/^__AGENT_ENV_EOF__$/p" "$WORK/out" | sed '1d;$d'; }
agent_env PLUGINS='code-review@claude-code-plugins' ORG_PLUGINS=$'knowledge@org\ncode-review@claude-code-plugins' \
  MARKETPLACES='https://x/a.git' ORG_MARKETPLACES='https://x/b.git'
expect "org plugins are added to the caller's, once each" test "$(multi_out plugins)" = $'code-review@claude-code-plugins\nknowledge@org'
expect "and their marketplaces too" test "$(multi_out marketplaces)" = $'https://x/a.git\nhttps://x/b.git'
expect "no env means no settings file" grep -qx 'settings=' "$WORK/out"
agent_env
expect "nothing set at all gives empty lists" test -z "$(multi_out plugins)$(multi_out marketplaces)"
agent_env AGENT_ENV=$'# a comment\nTOOL_RUNTIME=github-actions\nTOOL_EMAIL=a@b.c\nTOOL_TOKEN=plain' AGENT_ENV_SECRET=$'TOOL_TOKEN=s3cret\r'
expect "env lines become the agent's settings file, the secret's line winning without its CR" test "$(jq -c .env "$WORK/rt/agent-settings.json")" = '{"TOOL_RUNTIME":"github-actions","TOOL_EMAIL":"a@b.c","TOOL_TOKEN":"s3cret"}'
expect "and its value is masked" grep -qx '::add-mask::s3cret' "$WORK/log"
expect "a plain value is not masked" bash -c '! grep -q "add-mask::github-actions" "$1"' _ "$WORK/log"
expect "the log names keys, never values" bash -c 'grep -q "agent env: TOOL_EMAIL TOOL_RUNTIME TOOL_TOKEN" "$1" && ! grep -q "s3cret$" <(grep -v add-mask "$1")' _ "$WORK/log"
expect "the file is readable by the runner user only" test "$(stat -c %a "$WORK/rt/agent-settings.json" 2>/dev/null || stat -f %Lp "$WORK/rt/agent-settings.json")" = 600
for k in GH_TOKEN PATH ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN LD_PRELOAD NODE_OPTIONS GIT_SSH_COMMAND; do
  agent_env AGENT_ENV_SECRET="$k=x"; rc=$?
  expect "$k is refused, and fails the step" bash -c '[ "$1" != 0 ] && grep -q "Agent env key refused" "$2"' _ "$rc" "$WORK/log"
done
agent_env AGENT_ENV='not a key value line'
expect "a line that is not KEY=VALUE fails" grep -q 'Agent env line refused' "$WORK/log"

# 8e. run-agent's validate step: only a differing file stops the agent.
# validate HERE DEFAULT: the two copies gh returns; empty means unreadable.
validate() {
  : > "$WORK/out"
  ( cd "$WORK" && env -i PATH="$WORK/val-bin:$PATH" HOME="$WORK" RUNNER_TEMP="$WORK" REPO=o/r \
      WORKFLOW_REF='o/r/.github/workflows/deps.yml@refs/pull/7/merge' SHA=abc DEFAULT_BRANCH=develop \
      STUB_HERE="$1" STUB_DEFAULT="$2" GITHUB_OUTPUT="$WORK/out" bash "$WORK/validate.sh" ) > "$WORK/log" 2>&1
}
mkdir -p "$WORK/val-bin"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' \
  '  *"ref=abc"*)     [ -n "$STUB_HERE" ] && echo "$STUB_HERE" ;;' \
  '  *"ref=develop"*) [ -n "$STUB_DEFAULT" ] && echo "$STUB_DEFAULT" ;;' 'esac' > "$WORK/val-bin/gh"
chmod +x "$WORK/val-bin/gh"
validate same same
expect "an identical file starts the agent" bash -c '! grep -q skipped= "$1"' _ "$WORK/out"
validate new old
expect "a differing file does not" grep -qx 'skipped=workflow-mismatch' "$WORK/out"
expect "and names the file and the branch" grep -qF 'why=claude-code-action refuses to run while .github/workflows/deps.yml at this run' "$WORK/out"
validate '' old
expect "an unreadable copy starts the agent as before" bash -c '! grep -q skipped= "$1"' _ "$WORK/out"

# 9. The actor step: the App that pushed a fix round may start the agent on it.
# actor ACTOR: runs the step in $WORK/r; prints its fix-pusher output.
actor() {
  : > "$WORK/out"
  ( cd "$WORK/r" && env -i PATH="$PATH" HOME="$WORK" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      FIX_EMAIL="$FIX_EMAIL" ACTOR="$1" GITHUB_OUTPUT="$WORK/out" bash "$WORK/actor.sh" ) > "$WORK/log" 2>&1
  sed -n 's/^fix-pusher=//p' "$WORK/out"
}
# A fix round as the push step writes it, on top of Renovate's commit.
repo; fix_round
expect "a fix round's pusher is allowed when it is a bot" test "$(actor 'some-app[bot]')" = ',some-app[bot]'
expect "a person needs no allowance (the action checks people itself)" test "$(actor 'someone')" = ''
repo
expect "a bot that pushed anything but a fix round is not allowed" test "$(actor 'some-app[bot]')" = ''
repo; echo x > "$WORK/r/a.ts"; git -C "$WORK/r" add -A; git -C "$WORK/r" -c user.name="$FIX_NAME" -c user.email="$FIX_EMAIL" commit -q -m 'fix: no trailer'
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
