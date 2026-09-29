#!/usr/bin/env bash
# Regression tests for the picker's fallback policy.
#
# The claim worth asserting is the table in the README: what each weight falls
# back to, and when. Above all, `heavy` never lands on the light pool, because
# a heavy job there runs out of memory. The fleet listings below are built from
# made-up runners in the shape `gh api /orgs/<org>/actions/runners` returns after
# the picker's own jq (name, labels as strings, status, busy).
#
# Run: actions/pick-runner/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# An explicit template is required: BSD/macOS `mktemp -d` with no template
# ignores TMPDIR. This org runs macOS runners, so that is not hypothetical.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pick-runner-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LIGHT='self-hosted,Linux,light'
LARGE='self-hosted,Linux,large'
MAC='self-hosted,macOS,ARM64'
HOSTED='ubuntu-latest'

# fleet <file> <pool:state>...   pool is light|large|mac, state is idle|busy|offline
fleet() {
  local f="$1" n=0 spec labels status busy items=()
  shift
  for spec in "$@"; do
    n=$((n+1))
    case "${spec%%:*}" in
      light) labels='"self-hosted","Linux","X64","docker","light"' ;;
      large) labels='"self-hosted","Linux","X64","docker","large"' ;;
      mac)   labels='"self-hosted","macOS","ARM64","large"' ;;
    esac
    case "${spec##*:}" in
      idle)    status=online;  busy=false ;;
      busy)    status=online;  busy=true ;;
      offline) status=offline; busy=false ;;
    esac
    items+=("{\"name\":\"runner-$n\",\"labels\":[$labels],\"status\":\"$status\",\"busy\":$busy}")
  done
  local IFS=,
  echo "[${items[*]:-}]" > "$f"
}

pass=0; fail=0
check() { # <desc> <want runner> <want fell-back> <got runner> <got fell-back>
  local mark
  if [ "$2" = "$4" ] && [ "$3" = "$5" ]; then mark="ok  "; pass=$((pass+1))
  else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %s %-58s runner=%-24s fell-back=%s\n' "$mark" "$1" "$4" "$5"
  [ "$mark" = "ok  " ] || printf '       wanted runner=%s fell-back=%s\n' "$2" "$3"
}

# pick <desc> <want selector> <want fell-back> <fleet file, or "none"> [ENV=value ...]
pick() {
  local desc="$1" want="$2" wantfb="$3" file="$4"; shift 4
  export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
  local -a e=(PRIVATE=true FORK=false GUARD=true WEIGHT=light LABELS= FALLBACK= FALLBACK_WHEN= HOSTED_RUNNER="$HOSTED")
  env "${e[@]}" "$@" bash "$HERE/pick.sh" resolve >"$TMP/log" 2>&1
  local sel hosted
  sel=$(grep '^selector=' "$GITHUB_OUTPUT" | cut -d= -f2-)
  hosted=$(grep '^hosted=' "$GITHUB_OUTPUT" | cut -d= -f2-)
  : > "$GITHUB_OUTPUT"
  [ "$file" = none ] && file="$TMP/absent"
  env "${e[@]}" "$@" SELECTOR="$sel" HOSTED_ONLY="$hosted" FLEET_FILE="$file" \
    bash "$HERE/pick.sh" decide >"$TMP/log" 2>&1
  local got gotfb
  got=$(grep '^runner=' "$GITHUB_OUTPUT" | cut -d= -f2- | jq -r 'join(",")')
  gotfb=$(grep '^fell-back=' "$GITHUB_OUTPUT" | cut -d= -f2-)
  check "$desc" "$want" "$wantfb" "$got" "$gotfb"
}

warned() { # <desc> <substring of the warning>
  local mark
  if grep -q "::warning.*$2" "$TMP/log"; then mark="ok  "; pass=$((pass+1))
  else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %s %s\n' "$mark" "$1"
}

F="$TMP/fleet.json"

echo "== light: the light pool when nothing is idle (unchanged) =="
fleet "$F" light:idle light:busy
pick "idle runner"                     "$LIGHT" false "$F"
fleet "$F" light:busy light:busy
pick "all busy, stays on the light pool" "$LIGHT" false "$F"
fleet "$F" light:offline light:offline
pick "all offline, no other pool to try" "$LIGHT" false "$F"
fleet "$F" light:busy light:idle
pick "mixed, one idle"                 "$LIGHT" false "$F"
fleet "$F" light:busy
pick "fallback equal to the selector is not a fall back" "$LIGHT" false "$F" FALLBACK="$LIGHT"
if grep -q "falling back" "$TMP/log"; then fail=$((fail+1)); echo "  FAIL  ...logs no 'falling back' line"; else pass=$((pass+1)); echo "  ok    ...logs no 'falling back' line"; fi
fleet "$F" light:busy light:busy
pick "light + fallback-when offline queues when busy" "$LIGHT" false "$F" FALLBACK_WHEN=offline

echo "== heavy: never the light pool =="
fleet "$F" large:idle large:busy light:idle
pick "idle large runner"               "$LARGE" false "$F" WEIGHT=heavy
fleet "$F" large:busy large:busy light:idle
pick "all large busy queues on large"  "$LARGE" false "$F" WEIGHT=heavy
fleet "$F" large:offline large:offline light:idle
pick "all large offline goes hosted"   "$HOSTED" true "$F" WEIGHT=heavy
fleet "$F" large:offline large:busy light:idle
pick "mixed offline and busy queues"   "$LARGE" false "$F" WEIGHT=heavy
fleet "$F" light:idle
pick "no large runner at all goes hosted, not light" "$HOSTED" true "$F" WEIGHT=heavy
warned "  ...and says the selector matches nothing" "matches nothing"
fleet "$F" large:offline light:idle
pick "custom hosted-runner is the heavy fallback" "macos-latest" true "$F" WEIGHT=heavy HOSTED_RUNNER=macos-latest
fleet "$F" large:busy
pick "heavy + fallback-when busy goes hosted when busy" "$HOSTED" true "$F" WEIGHT=heavy FALLBACK_WHEN=busy

echo "== apple: never falls back to Linux =="
fleet "$F" mac:idle light:idle
pick "idle mac runner"                 "$MAC" false "$F" WEIGHT=apple
fleet "$F" mac:busy light:idle
pick "busy mac queues"                 "$MAC" false "$F" WEIGHT=apple
fleet "$F" mac:offline light:idle
pick "offline mac queues, never light" "$MAC" false "$F" WEIGHT=apple
warned "  ...and warns that nothing is online" "offline"
fleet "$F" light:idle
pick "no mac runner at all queues"     "$MAC" false "$F" WEIGHT=apple
warned "  ...and warns" "matches nothing"

echo "== explicit inputs win over the weight's default =="
fleet "$F" large:busy light:idle
pick "explicit fallback keeps the weight's when: busy queues" "$LARGE" false "$F" WEIGHT=heavy FALLBACK="$LIGHT"
fleet "$F" large:offline light:idle
pick "heavy + explicit fallback, offline"        "$LIGHT" true "$F" WEIGHT=heavy FALLBACK="$LIGHT"
fleet "$F" light:busy
pick "light + explicit hosted fallback, busy"    "$HOSTED" true "$F" FALLBACK="$HOSTED"
fleet "$F" mac:offline
pick "apple + explicit hosted fallback, offline" "$HOSTED" true "$F" WEIGHT=apple FALLBACK="$HOSTED"
fleet "$F" large:busy
pick "explicit fallback and fallback-when together" "$HOSTED" true "$F" WEIGHT=heavy FALLBACK="$HOSTED" FALLBACK_WHEN=busy

echo "== labels: today's behaviour =="
fleet "$F" large:busy
pick "custom selector, busy: light fallback"     "$LIGHT" true "$F" LABELS="self-hosted,Linux,large"
fleet "$F" large:idle
pick "custom selector, idle"                     "self-hosted,Linux,large" false "$F" LABELS="self-hosted,Linux,large"
fleet "$F" large:busy
pick "custom selector, fallback-when offline"    "self-hosted,Linux,large" false "$F" LABELS="self-hosted,Linux,large" FALLBACK_WHEN=offline

echo "== selector that matches nothing =="
fleet "$F" light:idle
pick "label no runner carries"                   "$LIGHT" true "$F" LABELS="self-hosted,Linux,gpu"
warned "  ...names the missing label" "gpu"
fleet "$F" light:idle mac:idle
pick "labels exist, never together"              "$LIGHT" true "$F" LABELS="light,macOS"
warned "  ...says they are not together" "no single runner"

echo "== fleet cannot be read: queue, never guess =="
pick "no listing, light"                         "$LIGHT" false none
pick "no listing, heavy stays off light and hosted" "$LARGE" false none WEIGHT=heavy
pick "no listing, apple"                         "$MAC" false none WEIGHT=apple
pick "no listing, explicit fallback still queues" "$LARGE" false none WEIGHT=heavy FALLBACK="$HOSTED"
pick "no listing, gh failed"                     "$LARGE" false none WEIGHT=heavy FLEET_ERR="gh exited 1"
warned "  ...and warns it was not validated" "NOT validated"
echo '[]' > "$F"
pick "empty listing counts as unreadable"        "$LARGE" false "$F" WEIGHT=heavy FLEET_ERR=
warned "  ...and warns" "NOT validated"

echo "== hosted, and the public/fork guard =="
fleet "$F" large:idle light:idle
pick "weight hosted"                             "$HOSTED" false "$F" WEIGHT=hosted
pick "public repo, heavy"                        "$HOSTED" false "$F" WEIGHT=heavy PRIVATE=false
pick "public repo ignores an explicit fallback"  "$HOSTED" false "$F" WEIGHT=heavy PRIVATE=false FALLBACK="$LIGHT" FALLBACK_WHEN=busy
pick "fork PR, light"                            "$HOSTED" false "$F" FORK=true
pick "fork PR ignores an explicit fallback"      "$HOSTED" false "$F" FORK=true FALLBACK="$LIGHT"
pick "fork PR ignores labels"                    "$HOSTED" false "$F" FORK=true LABELS="$LARGE"
pick "public repo, guard off, self-hosted again" "$LIGHT" false "$F" PRIVATE=false GUARD=false

echo "== bad input =="
export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
if FALLBACK_WHEN=sometimes PRIVATE=true bash "$HERE/pick.sh" resolve >"$TMP/log" 2>&1; then
  fail=$((fail+1)); echo "  FAIL unknown fallback-when was accepted"
else pass=$((pass+1)); echo "  ok   unknown fallback-when is rejected"; fi
if WEIGHT=huge PRIVATE=true bash "$HERE/pick.sh" resolve >"$TMP/log" 2>&1; then
  fail=$((fail+1)); echo "  FAIL unknown weight was accepted"
else pass=$((pass+1)); echo "  ok   unknown weight is rejected"; fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
