#!/usr/bin/env bash
# The model policy's whole decision, as a standalone script so `test.sh` can
# assert it without a runner. Writes `model`, `max-turns` and `route` to
# $GITHUB_OUTPUT. run-agent calls it before every agent run.
#
# The model ids live here and nowhere else. A model bump is one line below, and
# self-test fails any workflow that names an id itself.
#
# Reads STAGE, EFFORT, PRIORITY, RISK (the issue fields, empty when unknown),
# SIGNALS (space-separated facts the gate passes as it has them: red, an update
# kind major|minor|patch|lockfile|unknown, a review mode full|scoped, elevated,
# lint-only; an unknown word fails), ROUND
# (the fix round about to run, 1 is the first), MODEL (a caller override), PIN
# (the org's emergency pin) and MAX_TURNS (a caller's cap).
#
# Precedence: PIN, then MODEL, then the policy. A caller's MAX_TURNS wins over
# the policy's cap.
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"

OPUS='claude-opus-5-5'
SONNET='claude-sonnet-5-5'
HAIKU='claude-haiku-5-5'

lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
STAGE=$(lc "${STAGE:-}")
EFFORT=$(lc "${EFFORT:-}"); PRIORITY=$(lc "${PRIORITY:-}"); RISK=$(lc "${RISK:-}")
SIGNALS=" $(lc "${SIGNALS:-}") "
ROUND="${ROUND:-}"
case "$ROUND" in ''|*[!0-9]*) ROUND=1 ;; esac

for w in $SIGNALS; do
  case "$w" in
    red|major|minor|patch|lockfile|unknown|full|scoped|elevated|lint-only) ;;
    *) echo "::error title=Unknown agent signal::signal '$w' means nothing to the model policy, so it would pick as if it were absent."; exit 1 ;;
  esac
done
has() { case "$SIGNALS" in *" $1 "*) return 0 ;; esac; return 1; }

# The fields that make a change expensive to get wrong. Priority only
# escalates when it is Urgent: triage leaves it unset whenever it cannot
# justify a level, so unset says nothing.
stakes() {
  case "$RISK" in high|critical) echo "Risk $RISK"; return ;; esac
  [ "$EFFORT" = high ] && { echo "Effort high"; return; }
  [ "$PRIORITY" = urgent ] && { echo "Priority urgent"; return; }
  true
}

model=''; turns=''; route=''
pick() { model="$1"; turns="$2"; route="$STAGE: $3"; }

case "$STAGE" in
  '')
    # A caller written before stages existed names its model itself. Keep it
    # running, and say what to add.
    if [ -n "${MODEL:-}" ]; then
      echo "::warning title=No agent stage::this run-agent call passes a model but no stage, so the model policy is skipped. Pass stage instead of model."
      pick "$MODEL" '' "no stage, the caller's model"
    else
      echo "::error title=No agent stage::run-agent needs a stage, or a model from a caller written before stages existed."
      exit 1
    fi ;;
  triage)     pick "$OPUS" '' "planning reads unfamiliar code and decides" ;;
  assist)     pick "$OPUS" '' "a person's open-ended request" ;;
  implement)
    s=$(stakes)
    if [ -n "$s" ]; then pick "$OPUS" '' "$s"
    elif [ -z "$RISK" ] || [ -z "$EFFORT" ]; then pick "$OPUS" '' "Risk or Effort unset"
    else pick "$SONNET" '' "Risk $RISK, Effort $EFFORT"; fi ;;
  fix-ci)
    s=$(stakes)
    if [ "$ROUND" -ge 2 ]; then pick "$OPUS" 60 "round $ROUND, an earlier round did not fix it"
    elif [ -n "$s" ]; then pick "$OPUS" 60 "$s"
    elif has lint-only; then pick "$HAIKU" 30 "round 1, only lint or format failed"
    else pick "$SONNET" 60 "round 1"; fi ;;
  fix-review) pick "$OPUS" 60 "review findings need judgement" ;;
  review)
    if has elevated; then pick "$OPUS" '' "sensitive paths or a sec: label"
    elif has scoped; then pick "$SONNET" '' "scoped to trailered dependency commits"
    else pick "$OPUS" '' "full review, the last check before a merge"; fi ;;
  deps-verify)
    if has red; then pick "$OPUS" 80 "CI is red"
    elif has major; then pick "$OPUS" 40 "major update"
    elif has patch || has lockfile; then pick "$HAIKU" 30 "green patch or lockfile update"
    else pick "$SONNET" 40 "green minor update"; fi ;;
  fleet-sync) pick "$SONNET" 40 "edits that ship to every repo" ;;
  *)
    echo "::error title=Unknown agent stage::stage '${STAGE}' is not one of triage implement fix-ci fix-review review deps-verify fleet-sync assist."
    exit 1 ;;
esac

if [ -n "${PIN:-}" ]; then
  route="pinned by AGENT_MODEL_PIN (policy: $model, $route)"; model="$PIN"
elif [ -n "${MODEL:-}" ]; then
  route="caller override (policy: $model, $route)"; model="$MODEL"
fi
[ -z "${MAX_TURNS:-}" ] || turns="$MAX_TURNS"

{ echo "model=$model"; echo "max-turns=$turns"; echo "route=$route"; } >> "$GITHUB_OUTPUT"
echo "model=$model max-turns=${turns:-default} ($route)"
