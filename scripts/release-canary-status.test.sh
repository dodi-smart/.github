#!/usr/bin/env bash
# Tests for scripts/release-canary-status.sh with `gh` stubbed, so nothing
# reaches GitHub. The stub logs its arguments, one per line, or fails when told to.
#
# Run: scripts/release-canary-status.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POST="$HERE/release-canary-status.sh"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-status-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1" >&2; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in '$2')" ;; esac; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/gh.log" GITHUB_STEP_SUMMARY="$TMP/summary"
export REPO=o/r SHA=abc123 RUN_URL="https://example.test/run/1"

# post <result>  -> sets $rc and $log (what gh was asked) and $summary.
# UNSET=<name> runs it without that variable.
post() {
  : > "$STUB_LOG"; : > "$GITHUB_STEP_SUMMARY"
  env ${UNSET:+-u "$UNSET"} RESULT="$1" "$POST" >"$TMP/out" 2>"$TMP/err"; rc=$?
  log="$(cat "$STUB_LOG")"
  summary="$(cat "$GITHUB_STEP_SUMMARY")"
}

# Only a successful call is a success. Anything else must not read as one,
# promote.yml holds on it.
for pair in success:success failure:failure cancelled:failure skipped:failure; do
  result="${pair%%:*}" state="${pair##*:}"
  post "$result"
  eq "$result: the script succeeds" "$rc" 0
  has "$result: it posts to the statuses of the commit" "$log" "repos/o/r/statuses/abc123"
  has "$result: state is $state" "$log" "state=$state"
  has "$result: the context is release-canary" "$log" "context=release-canary"
  has "$result: the description carries the result" "$log" "pr-checks result against this release: $result"
  has "$result: the status links the run" "$log" "target_url=https://example.test/run/1"
  has "$result: the summary says what was posted" "$summary" "release-canary: $state on abc123 ($result)"
done

# A result it has never heard of is a failure, not a pass.
post ""; has "an empty result posts failure" "$log" "state=failure"
post banana; has "an unknown result posts failure" "$log" "state=failure"

# A status that could not be posted fails the job rather than being lost.
STUB_FAIL=1 post success; eq "a failed API call fails the script" "$rc" 1

# Anything the status needs is required.
for var in REPO SHA RUN_URL; do
  UNSET=$var post success
  eq "no $var is refused" "$rc" 1
  eq "no $var: nothing is posted" "$log" ""
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
