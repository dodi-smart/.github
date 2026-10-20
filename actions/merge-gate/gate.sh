#!/usr/bin/env bash
# The one merge gate. Every workflow that merges a pull request unattended
# decides here, so the checks that make a merge safe exist once. No agent reads
# anything: every input is a label, a check run, a status or a commit author.
#
# agent-gate has already stopped `agent:no-touch`, a draft and the wrong author
# kind before this runs. Then, in order:
#   1. the kill switch (the caller's org variable) is not 'false'
#   2. the policy's own rule:
#        deps  the update is minor, patch or lockfile (deps-intent's `kind`),
#              no `deps:needs-manual`, `renovate/stability-days` not pending, no
#              conflict with the base (a conflict asks for a rebase instead), and
#              `deps:verified`, or `deps:fixed` with `review / verdict`
#              approving the head
#        factory  the PR carries `agent:iterate`, its issue has no
#              `agent:no-touch`, the issue's fields put it on the `merge` tier
#              (actions/factory, the one place the tier is computed), no
#              conflict with the base (the fix loop merges the base in; nothing
#              here asks anyone to rebase), and `review / verdict` approves the head
#   3. the required check is `success` on the head commit
#   4. every commit on the PR is by an allowed author
#
# `tick` is the rebase request's text edit, kept here so test.sh covers it.
# `squash-body` reads the PR's commit messages, one base64 per line, and prints
# their trailers, each once, in the order first seen: the body of a factory squash.
# `run` reads the inputs from the API and writes merge/rebase/reason/kind to
# $GITHUB_OUTPUT; `decide` is the part test.sh runs on fixed inputs.
# LABELS, the input, and labels, its lines, are two names on purpose.
# shellcheck disable=SC2153
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The review contract: the context pr-review posts. Not an input, on purpose.
REVIEW_CONTEXT='review / verdict'
# Renovate's minimumReleaseAge status. No branch rule requires it.
AGE_CONTEXT='renovate/stability-days'

has() { grep -qxF "$1" <<<"$labels"; }

# Sets merge, rebase, reason and kind from POLICY, LABELS, TITLE, KILL, CHECK,
# REVIEW, FOREIGN (commit authors outside the allowed list), for deps AGE (the
# stability-days state) and MERGEABLE (the PR's mergeable_state), and for
# factory TIER and ISSUE_NO_TOUCH.
decide() {
  labels=$(jq -r '.[]' <<<"$LABELS")
  merge=false rebase=false
  kind=$(LABELS="$LABELS" TITLE="${TITLE:-}" "$HERE/../deps-intent/intent.sh" kind)
  if [ "${KILL:-}" = false ]; then reason="the kill switch is 'false'"; return; fi
  case "$POLICY" in
    deps)
      case "$kind" in
        minor|patch|lockfile) ;;
        major) reason="a major update: a person merges it"; return ;;
        *)     reason="the update kind cannot be told from labels or title"; return ;;
      esac
      if has deps:needs-manual; then reason="deps:needs-manual"; return; fi
      # Before the conflict rule: Renovate will not rebase before the age is met.
      if [ "${AGE:-}" = pending ]; then reason="Renovate's minimum release age is not met yet ($AGE_CONTEXT is pending)"; return; fi
      # The rebased head is judged again by deps-verify, whose label returns it here.
      if [ "${MERGEABLE:-}" = dirty ]; then rebase=true; reason="the branch conflicts with its base, so Renovate is asked to rebase it"; return; fi
      if has deps:fixed; then
        [ "$REVIEW" = success ] || { reason="deps:fixed waits for $REVIEW_CONTEXT to approve (it is ${REVIEW:-missing})"; return; }
      elif ! has deps:verified; then
        reason="no verification verdict yet"; return
      fi ;;
    factory)
      has agent:iterate || { reason="no agent:iterate"; return; }
      if [ "${ISSUE_NO_TOUCH:-}" = true ]; then reason="agent:no-touch on the issue"; return; fi
      [ "${TIER:-}" = merge ] || { reason="tier ${TIER:-draft}: a person merges it"; return; }
      # No rebase box here: the loop's update job merges the base into the branch.
      if [ "${MERGEABLE:-}" = dirty ]; then reason="the branch conflicts with its base; the fix loop brings it up to date"; return; fi
      [ "$REVIEW" = success ] || { reason="waits for $REVIEW_CONTEXT to approve (it is ${REVIEW:-missing})"; return; } ;;
    *) reason="unknown policy '${POLICY}'"; return ;;
  esac
  if [ "$CHECK" != success ]; then reason="the required check is ${CHECK:-missing}"; return; fi
  if [ -n "${FOREIGN:-}" ]; then reason="a commit is by an author this policy does not merge: $FOREIGN"; return; fi
  merge=true
  case "$POLICY" in
    factory) reason="tier merge and approved, and the required check passed" ;;
    *) reason="$(has deps:fixed && echo 'deps:fixed and approved' || echo deps:verified), and the required check passed" ;;
  esac
}

# tick: Renovate's PR body on stdin, the body with its rebase box ticked on
# stdout. Exits 3 when the box is already ticked and 4 when there is none.
tick() {
  local body; body=$(cat)
  [[ $body == *'- [x] <!-- rebase-check -->'* ]] && return 3
  [[ $body == *'- [ ] <!-- rebase-check -->'* ]] || return 4
  printf '%s\n' "${body/'- [ ] <!-- rebase-check -->'/'- [x] <!-- rebase-check -->'}"
}

squash_body() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || printf '%s\n' "$line" | base64 -d | git interpret-trailers --parse
  done | awk 'NF && !seen[$0]++'
}

case "${1:-run}" in
  tick) tick; exit $? ;;
  squash-body) squash_body; exit 0 ;;
  decide) : "${LABELS:?}" "${POLICY:?}"; CHECK="${CHECK:-}" REVIEW="${REVIEW:-}" FOREIGN="${FOREIGN:-}" TIER="${TIER:-}"
          decide; printf 'merge=%s\nrebase=%s\nkind=%s\nreason=%s\n' "$merge" "$rebase" "$kind" "$reason"; exit 0 ;;
esac

: "${REPO:?}" "${PR:?}" "${SHA:?}" "${POLICY:?}" "${REQUIRED_CHECK:?}"
labels=$(jq -r '.[]' <<<"$LABELS")
CHECK='' REVIEW='' FOREIGN='' TIER='' ISSUE_NO_TOUCH='' AGE='' MERGEABLE="${MERGEABLE:-}"
# factory: the issue the PR closes, its kill switch and its tier. Implement
# writes `Closes #n` itself, so this reads our own output. No issue is draft.
if [ "$POLICY" = factory ] && has agent:iterate; then
  ISSUE=$(gh api "/repos/$REPO/pulls/$PR" --jq '.body // ""' 2>/dev/null \
            | grep -oiE '(closes|fixes|resolves) #[0-9]+' | head -n 1 | grep -oE '[0-9]+' || true)
  if [ -n "$ISSUE" ]; then
    if gh api "/repos/$REPO/issues/$ISSUE/labels?per_page=100" --jq '[.[].name]' 2>/dev/null | grep -q '"agent:no-touch"'; then
      ISSUE_NO_TOUCH=true
    fi
    TIER=$(REPO="$REPO" ISSUE="$ISSUE" GITHUB_OUTPUT=/dev/null "$HERE/../factory/factory.sh" fields | sed -n 's/^tier=//p')
  fi
fi
# Each read only when the labels leave something to decide: most refusals need none.
if has deps:verified || has deps:fixed || [ -n "$TIER" ]; then
  # The newest run of the required check on the head commit; a re-run replaces it.
  CHECK=$(gh api "/repos/$REPO/commits/$SHA/check-runs?check_name=$(jq -rn --arg n "$REQUIRED_CHECK" '$n|@uri')" \
            --jq '.check_runs | sort_by(.id) | last | (.conclusion // .status // empty)' 2>/dev/null || true)
  # A commit whose author GitHub cannot map has no login and counts as foreign.
  FOREIGN=$(gh api "/repos/$REPO/pulls/$PR/commits?per_page=100" --paginate --jq '.[] | (.author.login // "unknown")' \
              | sort -u | grep -vxF -f <(tr ',' '\n' <<<"$ALLOWED_AUTHORS") | tr '\n' ' ' || true)
  FOREIGN="${FOREIGN% }"
fi
if has deps:fixed || [ -n "$TIER" ] || { [ "$POLICY" = deps ] && has deps:verified; }; then
  # One read of the head's statuses; decide uses what its policy needs.
  STATUSES=$(gh api "/repos/$REPO/commits/$SHA/status" --jq '[.statuses[] | {context, state}]' 2>/dev/null || echo '[]')
  state_of() { jq -r --arg c "$1" '[.[] | select(.context == $c)][0].state // empty' <<<"$STATUSES" 2>/dev/null || true; }
  REVIEW=$(state_of "$REVIEW_CONTEXT")
  AGE=$(state_of "$AGE_CONTEXT")
fi
decide
{
  echo "merge=$merge"
  echo "rebase=$rebase"
  echo "kind=$kind"
  echo "reason=$reason"
} >> "$GITHUB_OUTPUT"
echo "#$PR at $SHA: kind=$kind check=${CHECK:-missing} review=${REVIEW:-missing} age=${AGE:-none} mergeable=${MERGEABLE:-unknown} foreign=${FOREIGN:-none} tier=${TIER:-none}"
echo "merge=$merge: $reason"
