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
#              no `deps:needs-manual`, and `deps:verified`, or `deps:fixed`
#              with `review / verdict` approving the head
#   3. the required check is `success` on the head commit
#   4. every commit on the PR is by an allowed author
#
# `run` reads the inputs from the API and writes merge/reason/kind to
# $GITHUB_OUTPUT; `decide` is the part test.sh runs on fixed inputs.
# LABELS, the input, and labels, its lines, are two names on purpose.
# shellcheck disable=SC2153
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The review contract: the context pr-review posts. Not an input, on purpose.
REVIEW_CONTEXT='review / verdict'

has() { grep -qxF "$1" <<<"$labels"; }

# Sets merge, reason and kind from POLICY, LABELS, TITLE, KILL, CHECK, REVIEW
# and FOREIGN (commit authors outside the allowed list).
decide() {
  labels=$(jq -r '.[]' <<<"$LABELS")
  merge=false
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
      if has deps:fixed; then
        [ "$REVIEW" = success ] || { reason="deps:fixed waits for $REVIEW_CONTEXT to approve (it is ${REVIEW:-missing})"; return; }
      elif ! has deps:verified; then
        reason="no verification verdict yet"; return
      fi ;;
    *) reason="unknown policy '${POLICY}'"; return ;;
  esac
  if [ "$CHECK" != success ]; then reason="the required check is ${CHECK:-missing}"; return; fi
  if [ -n "${FOREIGN:-}" ]; then reason="a commit is by an author this policy does not merge: $FOREIGN"; return; fi
  merge=true
  reason="$(has deps:fixed && echo 'deps:fixed and approved' || echo deps:verified), and the required check passed"
}

case "${1:-run}" in
  decide) : "${LABELS:?}" "${POLICY:?}"; CHECK="${CHECK:-}" REVIEW="${REVIEW:-}" FOREIGN="${FOREIGN:-}"
          decide; printf 'merge=%s\nkind=%s\nreason=%s\n' "$merge" "$kind" "$reason"; exit 0 ;;
esac

: "${REPO:?}" "${PR:?}" "${SHA:?}" "${POLICY:?}" "${REQUIRED_CHECK:?}"
labels=$(jq -r '.[]' <<<"$LABELS")
CHECK='' REVIEW='' FOREIGN=''
# Each read only when the labels leave something to decide: most refusals need none.
if has deps:verified || has deps:fixed; then
  # The newest run of the required check on the head commit; a re-run replaces it.
  CHECK=$(gh api "/repos/$REPO/commits/$SHA/check-runs?check_name=$(jq -rn --arg n "$REQUIRED_CHECK" '$n|@uri')" \
            --jq '.check_runs | sort_by(.id) | last | (.conclusion // .status // empty)' 2>/dev/null || true)
  # A commit whose author GitHub cannot map has no login and counts as foreign.
  FOREIGN=$(gh api "/repos/$REPO/pulls/$PR/commits?per_page=100" --paginate --jq '.[] | (.author.login // "unknown")' \
              | sort -u | grep -vxF -f <(tr ',' '\n' <<<"$ALLOWED_AUTHORS") | tr '\n' ' ' || true)
  FOREIGN="${FOREIGN% }"
fi
if has deps:fixed; then
  REVIEW=$(gh api "/repos/$REPO/commits/$SHA/status" \
             --jq "[.statuses[] | select(.context == \"$REVIEW_CONTEXT\")][0].state // empty" 2>/dev/null || true)
fi
decide
{
  echo "merge=$merge"
  echo "kind=$kind"
  echo "reason=$reason"
} >> "$GITHUB_OUTPUT"
echo "#$PR at $SHA: kind=$kind check=${CHECK:-missing} review=${REVIEW:-missing} foreign=${FOREIGN:-none}"
echo "merge=$merge: $reason"
