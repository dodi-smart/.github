#!/usr/bin/env bash
# Decide whether deps-verify has anything new to judge, before it starts a job.
#
# Renovate re-pushes a branch for reasons that change nothing the agent reads: a
# rebase of the same update, lock file maintenance. Each push used to run the
# agent again, at about 8 minutes of large-pool time. The judge is:
#   skip      the run ends here and the label and comment already on the PR stand.
#             Only when ALL hold: the build is green, the PR carries
#             `deps:verified` (or `deps:fixed` with its fix commits still on the
#             branch), and the diff hashes to what the last comment recorded.
#   lockfile  green lock file maintenance with nothing but lockfiles changed: no
#             changelog to read, so the build result is the whole verdict.
#   agent     everything else, and always for a build that is not green.
#
# The hash covers every changed file except lockfiles, so an unknown stack is
# covered without a list of its manifests. It keeps only the +/- lines of each
# patch, so a rebase onto a moved base gives the same hash. A file the API sends
# no patch for (binary, too large) hashes its blob id instead. An EMPTY hash
# never matches: a transitive bump with the same manifests is not unchanged.
#
# Reads the diff from the compare API, so it needs no checkout. `run` reads its
# inputs from the environment and writes judge/intent/update/reason to
# $GITHUB_OUTPUT; `hash`, `rounds`, `previous` and `decide` are the parts test.sh runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lockfiles only. A version catalog or manifest is a change, so this is not the
# list deps-verify's push step refuses to edit, which does include the catalog.
LOCK_RE='(^|/)([^/]*\.(lock|lockb|lockfile)|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|go\.sum|Package\.resolved)$'

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# Hash of a compare payload on stdin (one JSON object per page), or nothing when
# no file besides a lockfile changed or the API cut the file list off at 300.
hash_diff() {
  local text
  text=$(jq -rs --arg re "$LOCK_RE" '
    [.[].files[]?] as $all
    | if ($all | length) >= 300 then empty else
        [$all[] | select(.filename | test($re) | not)] | sort_by(.filename)
        | if length == 0 then empty else
            map(.filename,
                (if .patch == null then "blob " + (.sha // "")
                 else .patch | split("\n") | map(select(test("^[+-]"))) | .[] end))
            | join("\n")
          end
      end')
  [ -n "$text" ] || return 0
  printf '%s\n' "$text" | sha
}

# Fix commits this job pushed, from a compare payload on stdin.
count_rounds() {
  jq -s '[.[].commits[]? | select(.commit.message | test("(^|\n)Deps-Verify-Round: "))] | length'
}

# The intent hash the last deps-verify comment recorded, from that comment's body.
previous_hash() {
  sed -n 's/.*<!-- deps-intent: \([0-9a-f]\{64\}\) -->.*/\1/p' | head -n 1
}

# Sets judge and reason from VERDICT, UPDATE, LABELS (a JSON array), ROUNDS,
# INTENT and PREVIOUS.
decide() {
  has() { printf '%s' "$LABELS" | jq -e --arg l "$1" 'index($l) != null' >/dev/null; }
  if [ "$VERDICT" != green ]; then
    judge=agent;    reason="the build is ${VERDICT:-not known yet}, so the agent reads it"
  elif [ "$UPDATE" = lockfile ] && [ -z "$INTENT" ]; then
    judge=lockfile; reason="lock file maintenance with a green build: nothing to read"
  elif [ -z "$INTENT" ]; then
    judge=agent;    reason="no diff to compare, so this update is judged again"
  elif [ "$INTENT" != "$PREVIOUS" ]; then
    judge=agent;    reason="the diff is new since the last verdict"
  elif has deps:verified; then
    judge=skip;     reason="same diff as the verdict already on the PR (deps:verified)"
  elif has deps:fixed && [ "${ROUNDS:-0}" -gt 0 ]; then
    judge=skip;     reason="same diff, and the fix commits are still on the branch (deps:fixed)"
  else
    judge=agent;    reason="the PR carries no verified or fixed label to keep"
  fi
}

case "${1:-run}" in
  hash)     hash_diff; exit 0 ;;
  rounds)   count_rounds; exit 0 ;;
  previous) previous_hash; exit 0 ;;
  decide) : "${UPDATE:?}" "${LABELS:?}"; VERDICT="${VERDICT:-}" ROUNDS="${ROUNDS:-0}"
          INTENT="${INTENT:-}" PREVIOUS="${PREVIOUS:-}"
          decide; printf 'judge=%s\nreason=%s\n' "$judge" "$reason"; exit 0 ;;
esac

: "${REPO:?}" "${BASE_REF:?}" "${HEAD_SHA:?}" "${NUMBER:?}" "${LABELS:?}"
VERDICT="${VERDICT:-}"
# The PR's labels as they are now. The event payload is a snapshot from the
# push, and a re-run replays it, so a verdict label set since then would be
# invisible and nothing could ever skip. Falls back to the payload.
LABELS="$(gh api "/repos/$REPO/issues/$NUMBER/labels?per_page=100" --jq '[.[].name]' 2>/dev/null || printf '%s' "$LABELS")"

UPDATE=other
printf '%s' "${TITLE:-}" | grep -qi 'lock file maintenance' && UPDATE=lockfile
printf '%s' "$LABELS" | jq -e 'index("deps:major")' >/dev/null && UPDATE=major

compare="$(gh api "/repos/$REPO/compare/$BASE_REF...$HEAD_SHA?per_page=100" --paginate)"
INTENT="$(printf '%s' "$compare" | hash_diff)"
ROUNDS="$(printf '%s' "$compare" | count_rounds)"
PREVIOUS=""
# The comment is only worth reading when a match could skip the run.
if [ "$VERDICT" = green ] && [ -n "$INTENT" ]; then
  PREVIOUS="$(gh api "/repos/$REPO/issues/$NUMBER/comments?per_page=100" --paginate \
                | "$HERE/../sticky-comment/sticky.sh" --body deps-verify | previous_hash)"
fi
decide

{
  echo "judge=$judge"
  echo "intent=$INTENT"
  echo "update=$UPDATE"
  echo "reason=$reason"
} >> "$GITHUB_OUTPUT"
echo "diff hash: ${INTENT:-none} (previous: ${PREVIOUS:-none})"
echo "judge: $judge, $reason"
if [ "$judge" = skip ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf 'Verification skipped: %s.\n' "$reason" >> "$GITHUB_STEP_SUMMARY"
fi
