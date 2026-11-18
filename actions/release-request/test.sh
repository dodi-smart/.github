#!/usr/bin/env bash
# Assert that a refused, skipped or unserved request label comes off, by its owner.
#
# Bug: closed PRs kept `agent:review`. pr-review cleared it only in its `review`
# job, which a gate refusal, a skipped gate job (a draft, a bot's PR a person
# labelled) or an early cancel never reaches, and deps-verify never cleared it.
# A label already present emits no `labeled` event, so asking again did nothing.
# Fix: a `release` job in both workflows running release.sh. `gh` is a stub.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-request-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

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

# run OWNER AUTHOR SENDER [STUB]
run() {
  : > "$WORK/gh.log"
  ( env -i PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" GH_STUB="${4:-ok}" GH_TOKEN=t REPO=o/r PR=7 \
      OWNER="$1" LABEL=agent:review AUTHOR="$2" SENDER="$3" "$HERE/release.sh" ) > "$WORK/out" 2>&1
  echo $? > "$WORK/rc"
}
called()    { grep -qx 'api -X DELETE /repos/o/r/issues/7/labels/agent%3Areview --silent' "$WORK/gh.log"; }
notcalled() { ! [ -s "$WORK/gh.log" ]; }
rc0()       { [ "$(cat "$WORK/rc")" = 0 ]; }
quiet()     { ! grep -q '::warning' "$WORK/out"; }

echo "== pr-review owns every request but a person's on a dependency PR =="
run pr-review alice alice
expect "a person's PR: removed"                          called
run pr-review 'claude[bot]' alice
expect "claude[bot]'s PR a person labelled: removed"     called
run pr-review 'some-app[bot]' alice
expect "an automation's PR a person labelled: removed"   called
run pr-review 'renovate[bot]' 'some-org-app[bot]'
expect "a bot's request on a dependency PR: removed"     called
run pr-review 'renovate[bot]' alice
expect "a person's request on a dependency PR: left"     notcalled

echo "== deps-verify owns a person's request on a dependency PR, and nothing else =="
run deps-verify 'renovate[bot]' alice
expect "a person's request on a dependency PR: removed"  called
run deps-verify 'renovate[bot]' 'some-org-app[bot]'
expect "the App's request (pr-review's): left"           notcalled
run deps-verify 'renovate[bot]' app/some-org-app
expect "an app/ sender is a bot too: left"               notcalled
run deps-verify alice alice
expect "a person's PR (pr-review's): left"               notcalled

echo "== failures =="
run pr-review alice alice 404
expect "a 404 is silent"                                 quiet
expect "and does not fail the job"                       rc0
run pr-review alice alice 403
expect "any other failure warns the request stays on"    grep -q '::warning title=agent:review not removed::#7 keeps agent:review' "$WORK/out"
expect "and does not fail the job"                       rc0
run nobody alice alice
expect "an unknown owner removes nothing"                notcalled
expect "and warns"                                       grep -q "unknown owner 'nobody'" "$WORK/out"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
