#!/usr/bin/env bash
# Regression tests for the static picker.
#
# What is worth asserting: each weight's labels, that `labels` wins, that nothing
# in the environment repoints a weight (there is no run-time switch), that the
# deprecated `fallback` inputs warn and change nothing, that a public repo or fork
# PR can never reach self-hosted, and that the picker makes no API call at all.
#
# Run: actions/pick-runner/test.sh   (bash 3.2 and 5)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR. This org runs macOS runners, so that is not hypothetical.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pick-runner-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LIGHT='self-hosted,Linux,light'
LARGE='self-hosted,Linux,large'
AGENT='self-hosted,Linux,agent'
MAC='self-hosted,macOS,ARM64'
HOSTED='ubuntu-latest'

pass=0; fail=0
check() { # <desc> <want runner> <want selector> <got runner> <got selector> <got fell-back>
  local mark
  if [ "$2" = "$4" ] && [ "$3" = "$5" ] && [ "$6" = "false" ]; then mark="ok  "; pass=$((pass+1))
  else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %s %-58s runner=%-24s fell-back=%s\n' "$mark" "$1" "$4" "$6"
  [ "$mark" = "ok  " ] || printf '       wanted runner=%s selector=%s fell-back=false, got selector=%s\n' "$2" "$3" "$5"
}

# pick <desc> <want runner (comma-joined)> <want selector> [ENV=value ...]
pick() {
  local desc="$1" want="$2" wantsel="$3"; shift 3
  export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
  local -a e=(PRIVATE=true FORK=false GUARD=true WEIGHT=light LABELS= HOSTED_RUNNER="$HOSTED")
  env "${e[@]}" "$@" bash "$HERE/pick.sh" >"$TMP/log" 2>&1
  local got sel fb
  got=$(grep '^runner=' "$GITHUB_OUTPUT" | cut -d= -f2- | jq -r 'join(",")')
  sel=$(grep '^selector=' "$GITHUB_OUTPUT" | cut -d= -f2-)
  fb=$(grep '^fell-back=' "$GITHUB_OUTPUT" | cut -d= -f2-)
  check "$desc" "$want" "$wantsel" "$got" "$sel" "$fb"
}

not_warned() { # <desc> <substring that must not be warned>
  local mark
  if grep -q "::warning.*$2" "$TMP/log"; then mark="FAIL"; fail=$((fail+1))
  else mark="ok  "; pass=$((pass+1)); fi
  printf '  %s %s\n' "$mark" "$1"
}

warned() { # <desc> <substring of the warning>
  local mark
  if grep -q "::warning.*$2" "$TMP/log"; then mark="ok  "; pass=$((pass+1))
  else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %s %s\n' "$mark" "$1"
}

echo "== each weight resolves to its labels =="
pick "light"                                     "$LIGHT"  "$LIGHT"
pick "heavy"                                     "$LARGE"  "$LARGE"  WEIGHT=heavy
pick "agent"                                     "$AGENT"  "$AGENT"  WEIGHT=agent
pick "apple"                                     "$MAC"    "$MAC"    WEIGHT=apple
pick "hosted"                                    "$HOSTED" ""        WEIGHT=hosted
pick "custom hosted-runner for weight hosted"    "macos-latest" ""   WEIGHT=hosted HOSTED_RUNNER=macos-latest
pick "weight defaults to light when unset"       "$LIGHT"  "$LIGHT"  WEIGHT=

echo "== the legacy inputs change nothing =="
pick "fallback is ignored"                       "$LIGHT"  "$LIGHT"  FALLBACK="$HOSTED" FALLBACK_WHEN=offline
warned "  ...and warns that fallback is deprecated" "\`fallback\` is ignored"
warned "  ...and names fallback-when too" "\`fallback-when\` is ignored"
pick "heavy ignores fallback too"                "$LARGE"  "$LARGE"  WEIGHT=heavy FALLBACK="$LIGHT" FALLBACK_WHEN=busy
pick "an unknown fallback-when is not an error"  "$LIGHT"  "$LIGHT"  FALLBACK_WHEN=sometimes
pick "no fallback set, no warning"               "$LIGHT"  "$LIGHT"
not_warned "  ...is silent" "Deprecated pick-runner input"
pick "app credentials are ignored"               "$LIGHT"  "$LIGHT"  GH_APP_CLIENT_ID=x GH_APP_PRIVATE_KEY=y

echo "== labels win over weight =="
pick "labels override"                           "self-hosted,Linux,docker" "self-hosted,Linux,docker" LABELS="self-hosted,Linux,docker"
pick "labels beat weight"                        "self-hosted,Linux,docker" "self-hosted,Linux,docker" WEIGHT=apple LABELS="self-hosted,Linux,docker"
pick "labels are trimmed"                        "self-hosted,Linux,gpu" "self-hosted , Linux , gpu" LABELS="self-hosted , Linux , gpu"
echo "== nothing in the environment repoints a weight =="
pick "a DODI_RUNS_ON_LIGHT left in env changes nothing"  "$LIGHT" "$LIGHT" DODI_RUNS_ON_LIGHT='"ubuntu-latest"'
pick "a DODI_RUNS_ON_HEAVY left in env changes nothing"  "$LARGE" "$LARGE" WEIGHT=heavy DODI_RUNS_ON_HEAVY='"ubuntu-latest"'
pick "a RUNS_ON_AGENT left in env changes nothing"       "$AGENT" "$AGENT" WEIGHT=agent RUNS_ON_AGENT='"ubuntu-latest"'
pick "a DODI_RUNS_ON_APPLE left in env changes nothing"  "$MAC"   "$MAC"   WEIGHT=apple DODI_RUNS_ON_APPLE='["self-hosted","macOS"]'
if grep -qE 'DODI_RUNS_ON|RUNS_ON_' "$HERE/pick.sh" "$HERE/action.yml"; then
  echo "  FAIL the picker still reads a run-time override"; fail=$((fail+1))
else
  echo "  ok   the picker reads no run-time override"; pass=$((pass+1))
fi

echo "== the public/fork guard has no opt-out =="
pick "public repo, light"                        "$HOSTED" "" PRIVATE=false
pick "public repo, heavy"                        "$HOSTED" "" WEIGHT=heavy PRIVATE=false
pick "public repo, apple"                        "$HOSTED" "" WEIGHT=apple PRIVATE=false
pick "repository privacy unknown is public"      "$HOSTED" "" PRIVATE=
pick "fork PR, light"                            "$HOSTED" "" FORK=true
pick "fork PR, agent"                            "$HOSTED" "" WEIGHT=agent FORK=true
pick "fork PR ignores labels"                    "$HOSTED" "" FORK=true LABELS="$LARGE"
pick "fork PR ignores an override"               "$HOSTED" "" FORK=true DODI_RUNS_ON_LIGHT='["self-hosted","x"]'
pick "public repo ignores labels"                "$HOSTED" "" PRIVATE=false LABELS="$LARGE"
pick "public repo uses hosted-runner"            "macos-latest" "" PRIVATE=false HOSTED_RUNNER=macos-latest
pick "guard off on a public repo: self-hosted"   "$LIGHT" "$LIGHT" PRIVATE=false GUARD=false

echo "== bad input =="
export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
if WEIGHT=huge PRIVATE=true bash "$HERE/pick.sh" >"$TMP/log" 2>&1; then
  fail=$((fail+1)); echo "  FAIL unknown weight was accepted"
else pass=$((pass+1)); echo "  ok   unknown weight is rejected"; fi
if WEIGHT=huge PRIVATE=false bash "$HERE/pick.sh" >"$TMP/log" 2>&1; then
  pass=$((pass+1)); echo "  ok   unknown weight on a public repo is still hosted, not an error"
else fail=$((fail+1)); echo "  FAIL unknown weight on a public repo failed"; fi

echo "== no API call, no token, no fleet =="
if grep -rEq 'actions/runners|create-github-app-token|gh api|curl ' "$HERE/pick.sh" "$HERE/action.yml"; then
  fail=$((fail+1)); echo "  FAIL the picker reaches the API again"
else pass=$((pass+1)); echo "  ok   no API call in pick.sh or action.yml"; fi
# Run with no network tools and no token: it must still resolve.
export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
if env -i PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" GITHUB_OUTPUT="$GITHUB_OUTPUT" PRIVATE=true bash "$HERE/pick.sh" >"$TMP/log" 2>&1 \
   && grep -q '^runner=\["self-hosted","Linux","light"\]$' "$GITHUB_OUTPUT"; then
  pass=$((pass+1)); echo "  ok   resolves with an empty environment (no token, no network config)"
else fail=$((fail+1)); echo "  FAIL did not resolve with an empty environment"; fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
