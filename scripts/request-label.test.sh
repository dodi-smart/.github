#!/usr/bin/env bash
# Assert that a refused, skipped or unserved `agent:review` request comes off.
#
# Bug: 17 closed PRs across the org still carried `agent:review`. pr-review
# cleared it only in its `review` job, which a gate refusal, a skipped gate job
# (a draft, a bot's PR a person labelled) or an early cancel never reaches, and
# deps-verify never cleared it at all. A label already present emits no
# `labeled` event, so asking again did nothing. Fix: a `release` job in both
# workflows, keyed on actions/agent-gate's `requested` output.
#
# The `clear` step is lifted out of each workflow and run against a stubbed gh.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/request-label-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

python3 - "$ROOT" "$WORK" <<'EOF' || { echo 'cannot read the release jobs'; exit 1; }
import sys, yaml
root, work = sys.argv[1:3]
for f in ('pr-review', 'deps-verify'):
    steps = yaml.safe_load(open(root + '/.github/workflows/' + f + '.yml'))['jobs']['release']['steps']
    open(work + '/' + f + '.sh', 'w').write([s for s in steps if s.get('id') == 'clear'][0]['run'])
EOF

expect "both workflows run the same clear step" cmp -s "$WORK/pr-review.sh" "$WORK/deps-verify.sh"

# A gh that records its call and answers as GH_STUB says: ok, 404 or 403.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$GH_STUB" in
  ok)  exit 0 ;;
  404) echo 'gh: Label does not exist (HTTP 404)' >&2; exit 1 ;;
  *)   echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

# run OWNER REQUESTED KIND SENDER [STUB]
run() {
  : > "$WORK/gh.log"
  ( env -i PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" GH_STUB="${5:-ok}" GH_TOKEN=t REPO=o/r PR=7 \
      OWNER="$1" REQUESTED="$2" KIND="$3" SENDER="$4" bash "$WORK/$1.sh" ) > "$WORK/out" 2>&1
  echo $? > "$WORK/rc"
}
called()    { grep -qx 'api -X DELETE /repos/o/r/issues/7/labels/agent%3Areview --silent' "$WORK/gh.log"; }
notcalled() { ! [ -s "$WORK/gh.log" ]; }
rc0()       { [ "$(cat "$WORK/rc")" = 0 ]; }

echo "== pr-review owns every request but a person's on a dependency PR =="
run pr-review true human alice
expect "a person's PR: removed"                         called
run pr-review true agent alice
expect "claude[bot]'s PR a person labelled: removed"     called
run pr-review true automation alice
expect "an automation's PR a person labelled: removed"   called
run pr-review true dependency 'some-org-app[bot]'
expect "a bot's request on a dependency PR: removed"     called
run pr-review true dependency alice
expect "a person's request on a dependency PR: left"     notcalled
run pr-review false human alice
expect "not a request: nothing called"                   notcalled
run pr-review '' human alice
expect "requested unset: nothing called"                 notcalled

echo "== deps-verify owns a person's request on a dependency PR, and nothing else =="
run deps-verify true dependency alice
expect "a person's request on a dependency PR: removed"  called
run deps-verify true dependency 'some-org-app[bot]'
expect "the App's request (pr-review's): left"           notcalled
run deps-verify true dependency app/some-org-app
expect "an app/ sender is a bot too: left"               notcalled
run deps-verify true human alice
expect "a person's PR (pr-review's): left"               notcalled
run deps-verify false dependency alice
expect "not a request: nothing called"                   notcalled

echo "== failures =="
run pr-review true human alice 404
expect "a 404 is silent"                                 sh -c '! grep -q "::warning" "$0"' "$WORK/out"
expect "and does not fail the job"                       rc0
run pr-review true human alice 403
expect "any other failure warns the request stays on"    grep -q '::warning title=Request label kept::' "$WORK/out"
expect "and does not fail the job"                       rc0

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
