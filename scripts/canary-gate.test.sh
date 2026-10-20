#!/usr/bin/env bash
# Tests for scripts/canary-gate.sh with `gh` stubbed, so nothing reaches GitHub.
# The stub answers `gh api` from a JSON file, or fails when told to.
#
# Run: scripts/canary-gate.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/canary-gate.sh"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1" >&2; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in '$2')" ;; esac; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
cat "$STUB_BODY"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/gh.log" STUB_BODY="$TMP/body.json"
export GITHUB_REPOSITORY=o/r

SHA=0123456789abcdef0123456789abcdef01234567
URL="https://example.test/run/1"
# status <state> [context]  -> one status object
status() { printf '{"context":"%s","state":"%s","target_url":"%s"}' "${2:-release-canary}" "$1" "$URL"; }

# gate <mode>  -> sets $out (stdout), $err (stderr) and $rc
gate() {
  out="$("$GATE" "$@" 2>"$TMP/err")"; rc=$?
  err="$(<"$TMP/err")"
}
body() { printf '[%s]' "$(IFS=,; echo "$*")" > "$STUB_BODY"; }

# --- success: both modes go ahead
body "$(status success)"
gate auto "$SHA";   eq "success: auto proceeds" "$rc" 0
has "success: the reason names the run" "$out" "$URL"
eq "success: auto warns about nothing" "$err" ""
gate manual "$SHA"; eq "success: manual proceeds" "$rc" 0
eq "success: manual warns about nothing" "$err" ""
gate state "$SHA";  eq "success: state" "$out" success

# --- failure
body "$(status failure)"
gate auto "$SHA";   eq "failure: auto refuses" "$rc" 1
has "failure: auto says why on stdout" "$out" "is failure"
has "failure: auto annotates" "$err" "::warning title=Promotion held::"
gate manual "$SHA"; eq "failure: manual proceeds" "$rc" 0
has "failure: manual warns with the state" "$err" "::warning title=Promoting without a passing canary::"
has "failure: manual warning links the run" "$err" "$URL"
gate state "$SHA";  eq "failure: state" "$out" failure

# --- error is a failure
body "$(status error)"
gate auto "$SHA";   eq "error: auto refuses" "$rc" 1
gate manual "$SHA"; eq "error: manual proceeds" "$rc" 0

# --- pending: a canary that has not reported is not a pass
body "$(status pending)"
gate auto "$SHA";   eq "pending: auto refuses" "$rc" 1
has "pending: auto says it is pending" "$out" "is pending"
gate manual "$SHA"; eq "pending: manual proceeds" "$rc" 0
has "pending: manual warns with the state" "$err" "is pending"
gate state "$SHA";  eq "pending: state" "$out" pending

# --- missing: no status at all, and a status for some other context
body
gate auto "$SHA";   eq "missing: auto refuses" "$rc" 1
has "missing: auto says there is no result" "$out" "no release canary result"
gate manual "$SHA"; eq "missing: manual proceeds" "$rc" 0
has "missing: manual warns that there is no result" "$err" "no release canary result"
gate state "$SHA";  eq "missing: state" "$out" none
body "$(status success review/verdict)" "$(status success 'PR Checks')"
gate auto "$SHA";   eq "another context's success does not count" "$rc" 1
gate state "$SHA";  eq "another context only: state" "$out" none

# --- the newest status wins, whatever came before it
body "$(status failure)" "$(status success)"
gate auto "$SHA";   eq "a later failure beats an earlier success" "$rc" 1
body "$(status success)" "$(status failure)"
gate auto "$SHA";   eq "a rerun that passed beats the earlier failure" "$rc" 0
body "$(status pending)" "$(status success)"
gate auto "$SHA";   eq "a rerun still pending is not the earlier success" "$rc" 1

# --- API error: not "none", and not a pass
STUB_FAIL=1 gate auto "$SHA";   eq "API error: auto refuses" "$rc" 1
has "API error: auto says it could not be read" "$out" "could not be read"
STUB_FAIL=1 gate manual "$SHA"; eq "API error: manual proceeds" "$rc" 0
has "API error: manual warns" "$err" "could not be read"
STUB_FAIL=1 gate state "$SHA";  eq "API error: state is unreadable, not none" "$out" unreadable
echo 'not json' > "$STUB_BODY"
gate auto "$SHA";   eq "an unparsable answer: auto refuses" "$rc" 1
gate state "$SHA";  eq "an unparsable answer: state is unreadable" "$out" unreadable

# --- the call it makes
body "$(status success)"
: > "$STUB_LOG"
gate auto "$SHA"
has "it asks for the commit's statuses" "$(cat "$STUB_LOG")" "repos/o/r/commits/$SHA/statuses"

# --- usage
gate banana "$SHA"; eq "an unknown mode is a usage error" "$rc" 2
gate auto;          eq "a missing sha is a usage error" "$rc" 2

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
