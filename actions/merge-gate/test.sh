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

# $1 name, $2 want merge, then env assignments. The default is a mergeable
# verified minor with a green check and only allowed authors.
decide() {
  local name="$1" want="$2" got m r; shift 2
  got="$(env -i PATH="$PATH" POLICY=deps LABELS='["deps:verified","deps:minor"]' TITLE='chore(deps): update x' \
         CHECK=success REVIEW='' FOREIGN='' KILL='' "$@" "$HERE/gate.sh" decide)"
  m=$(sed -n 's/^merge=//p' <<<"$got"); r=$(sed -n 's/^reason=//p' <<<"$got")
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

decide "verified minor, green"                                    true
decide "verified patch, green"                                    true  'LABELS=["deps:verified","deps:patch"]'
decide "verified lock file maintenance, green"                    true  'LABELS=["deps:verified"]' TITLE='chore(deps): lock file maintenance'
decide "fixed patch, approved, green"                             true  'LABELS=["deps:fixed","deps:patch"]' REVIEW=success
decide "a Dependabot minor by title, verified, green"             true  'LABELS=["deps:verified"]' TITLE='Bump react from 19.0.0 to 19.1.0'

# `run` reads the check, the authors and the review only when a verdict label
# makes them matter. `gh` is a stub that records its calls.
mkdir -p "$WORK/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$STUB_CALLS"' 'case "$*" in' \
  '  *check-runs*) echo "$STUB_CHECK" ;;' \
  '  *"/commits?"*) printf "%s\n" $STUB_AUTHORS ;;' \
  '  */status*) echo "$STUB_REVIEW" ;;' 'esac' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
# run LABELS AUTHORS CHECK REVIEW
run() {
  : > "$WORK/calls"; : > "$WORK/out"
  env -i PATH="$WORK/bin:$PATH" STUB_CALLS="$WORK/calls" STUB_CHECK="$3" STUB_REVIEW="$4" STUB_AUTHORS="$2" \
    POLICY=deps REPO=o/r PR=7 SHA=abc LABELS="$1" TITLE='chore(deps): update x' KILL='' \
    REQUIRED_CHECK='checks / PR Checks' ALLOWED_AUTHORS='renovate[bot],dependabot[bot],github-actions[bot]' \
    GITHUB_OUTPUT="$WORK/out" "$HERE/gate.sh" run > /dev/null 2>&1
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
run '["deps:fixed","deps:patch"]' 'renovate[bot] github-actions[bot]' success success
check "run: a fixed, approved patch by allowed authors merges"   grep -qx 'merge=true' "$WORK/out"
check "run: the check name is URL-encoded"                       grep -qF 'check_name=checks%20%2F%20PR%20Checks' "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot] someone' success ''
check "run: a stranger's commit stops it"                        grep -qx 'reason=a commit is by an author this policy does not merge: someone' "$WORK/out"
run '["deps:minor"]' 'renovate[bot]' success success
check "run: no verdict label reads nothing else"                 bash -c '! grep -qE "check-runs|commits|status" "$1"' _ "$WORK/calls"
run '["deps:verified","deps:minor"]' 'renovate[bot]' success ''
check "run: verified reads the check, not the review"            bash -c 'grep -q check-runs "$1" && ! grep -q "/status" "$1"' _ "$WORK/calls"
check "run: and merges"                                          grep -qx 'merge=true' "$WORK/out"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
