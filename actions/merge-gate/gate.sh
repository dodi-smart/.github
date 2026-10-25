#!/usr/bin/env bash
# The one merge gate. Every workflow that merges a pull request unattended
# decides here, so the checks that make a merge safe exist once. No agent reads
# anything: every input is a label, a check run, a status or a commit author.
#
# agent-gate has already stopped `agent:no-touch`, a draft and the wrong author
# kind before this runs. Then, in order:
#   1. the kill switch (the caller's org variable) is not 'false'
#   2. the policy's own rule:
#        deps  the PR's base is the default branch (a security update opened
#              against the production branch is merged by a person, and only the
#              default branch takes unattended dependency merges), the update
#              is minor, patch or lockfile (deps-intent's `kind`),
#              no `deps:needs-manual`, `renovate/stability-days` not pending, no
#              conflict with the base (a conflict asks for a rebase instead), and
#              `deps:verified`, or `deps:fixed` with `review / verdict`
#              approving the head
#        backmerge  the clean back-merge PR a hotfix release opens: the head ref
#              starts with `chore/backmerge-`, the base is the default branch, no
#              conflict with the base, and the head commit is a merge of exactly
#              two parents: the first an ancestor of (or equal to) the base, the
#              second an ancestor of (or equal to) the release branch. It is
#              merged with a merge commit, never squashed or rebased: the
#              release commit and its tag must stay reachable from the default
#              branch. This policy has no labels and no commit-author rule: the
#              PR legitimately carries every commit the release branch has and
#              the base lacks, by any author, so the parent rule replaces the
#              author rule. Its kill switch is the caller's BACKMERGE_AUTOMERGE.
#              With `backmerge:regenerated` (the lock file was rebuilt rather
#              than merged) `review / verdict` must also approve the head.
#        factory  the PR carries `agent:iterate`, its issue has no
#              `agent:no-touch`, the issue's fields put it on the `merge` tier
#              (actions/factory, the one place the tier is computed), no
#              conflict with the base (the fix loop merges the base in; nothing
#              here asks anyone to rebase), and `review / verdict` approves the head
#        hotfix  a security patch on the hotfix lane: the base is the release
#              branch, actions/target-guard's verdict, derived again here from
#              the live PR, is `lane`, and no conflict with the base. A person
#              or an agent may have written it, so there is no author rule:
#              the lane's patch-only rule and the review stand in for it.
#              Squashed under its `fix:` title. Kill switch HOTFIX_AUTOMERGE.
#        standards-sync  the org App's standards sync: the head is
#              `chore/standards-sync`, the base is the default branch, the PR
#              and every commit are by the org App, no conflict, and
#              `standards / verify` and `standards / render` are `success` (no
#              new verify failure, and a pure render the agent pass did not
#              edit). Squashed. Kill switch SYNC_AUTOMERGE.
#   3. the required check is `success` on the head commit
#   4. every commit on the PR is by an allowed author (not for `backmerge` or
#      `hotfix`)
#   5. hotfix, standards-sync and a regenerated back-merge: `review / verdict`
#      approves the head. When it is missing and no `agent:review` request is in
#      flight, `review-wanted` has merge-gate request one (actions/request-review),
#      even when an earlier rule holds the merge: an agent-touched sync is
#      reviewed, then waits for a person.
#
# `tick` is the rebase request's text edit, kept here so test.sh covers it.
# `squash-body` reads the PR's commit messages, one base64 per line, and prints
# their trailers, each once, in the order first seen: the body of a factory squash.
# `run` reads the inputs from the API (nothing with the kill switch off) and
# writes merge/rebase/review-wanted/reason/kind to $GITHUB_OUTPUT; `decide` is the part test.sh runs on fixed inputs.
# LABELS, the input, and labels, its lines, are two names on purpose.
# shellcheck disable=SC2153
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
# The review contract: the context pr-review posts. Not an input, on purpose.
REVIEW_CONTEXT='review / verdict'
# Renovate's minimumReleaseAge status. No branch rule requires it.
AGE_CONTEXT='renovate/stability-days'
# What the standards sync posts on its PR: verify.sh found nothing new, and
# the render is pure (the agent pass edited nothing).
VERIFY_CONTEXT='standards / verify'
RENDER_CONTEXT='standards / render'
SYNC_BRANCH='chore/standards-sync'
REGENERATED='backmerge:regenerated'

has() { grep -qxF "$1" <<<"$labels"; }

# rules sets merge, rebase, needs_review, reason and kind from POLICY, LABELS, TITLE,
# KILL, CHECK, REVIEW, FOREIGN (commit authors outside the allowed list), for
# deps AGE (the stability-days state) and MERGEABLE (the PR's mergeable_state),
# for every policy but factory BASE_REF, for deps, backmerge and standards-sync
# DEFAULT_BRANCH, for
# backmerge and standards-sync HEAD_REF, for backmerge PARENTS (the head
# commit's parent count) and P1_REL, P2_REL (the compare API's status of each
# parent against the base and the release branch: `identical` or `ahead` means
# the parent is an ancestor of, or equal to, that branch), for factory TIER and
# ISSUE_NO_TOUCH, for hotfix RELEASE_BRANCH, LANE and LANE_REASON (target-guard's
# verdict and reason), and for standards-sync AUTHOR, APP_BOT (the org App's
# login), VERIFY and RENDER. decide runs it and sets review_wanted.
rules() {
  labels=$(jq -r '.[]' <<<"$LABELS")
  merge=false rebase=false needs_review=''
  kind=$(LABELS="$LABELS" TITLE="${TITLE:-}" "$HERE/../deps-intent/intent.sh" kind)
  if [ "${KILL:-}" = false ]; then reason="the kill switch is 'false'"; return; fi
  case "$POLICY" in
    deps)
      # A dependency update opened against the production branch, a security
      # fix above all, is read and merged by a person. An unreadable branch is a no.
      base_is "${DEFAULT_BRANCH:-}" 'the default branch' \
        "a dependency update into ${BASE_REF:-} waits for a person: only the default branch takes unattended dependency merges" || return 0
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
      fi
      ok="$(has deps:fixed && echo 'deps:fixed and approved' || echo deps:verified), and the required check passed" ;;
    backmerge)
      case "${HEAD_REF:-}" in
        chore/backmerge-?*) ;;
        *) reason="the head branch is not a chore/backmerge-* branch"; return ;;
      esac
      base_is "${DEFAULT_BRANCH:-}" 'the default branch' || return 0
      if [ "${MERGEABLE:-}" = dirty ]; then reason="the back-merge conflicts with $BASE_REF: a person resolves it"; return; fi
      # The head must be the merge the release made and nothing a person pushed
      # on top: two parents, the first already in the base, the second in the release.
      if [ "${PARENTS:-}" != 2 ]; then reason="the head commit is not a merge of two parents (it has ${PARENTS:-an unreadable number of})"; return; fi
      case "${P1_REL:-}" in identical|ahead) ;; *) reason="the first parent is not in $BASE_REF (compare says ${P1_REL:-unreadable})"; return ;; esac
      case "${P2_REL:-}" in identical|ahead) ;; *) reason="the second parent is not in the release branch (compare says ${P2_REL:-unreadable})"; return ;; esac
      if has "$REGENERATED"; then needs_review="a back-merge whose lock file was regenerated ($REGENERATED)"; fi
      ok="a clean merge of the release branch into $BASE_REF${needs_review:+, approved}, and the required check passed" ;;
    hotfix)
      base_is "$RELEASE_BRANCH" 'the release branch' || return 0
      if [ "${LANE:-}" != lane ]; then reason="target-guard's verdict is ${LANE:-unreadable}, not lane${LANE_REASON:+: $LANE_REASON}"; return; fi
      needs_review="a security patch on the hotfix lane"
      if [ "${MERGEABLE:-}" = dirty ]; then reason="the security patch conflicts with $BASE_REF: a person resolves it"; return; fi
      ok="a security patch on the lane into $BASE_REF, approved, and the required check passed" ;;
    standards-sync)
      if [ "${HEAD_REF:-}" != "$SYNC_BRANCH" ]; then reason="the head branch is ${HEAD_REF:-unreadable}, not $SYNC_BRANCH"; return; fi
      base_is "${DEFAULT_BRANCH:-}" 'the default branch' || return 0
      if [ -z "${APP_BOT:-}" ]; then reason="the org App's login could not be read, so the author cannot be checked"; return; fi
      if [ "${AUTHOR:-}" != "$APP_BOT" ]; then reason="the PR is by ${AUTHOR:-an unreadable author}, not the org App ($APP_BOT)"; return; fi
      needs_review="a standards sync"
      if [ "${MERGEABLE:-}" = dirty ]; then reason="the sync conflicts with $BASE_REF: a person resolves it, or the next sync replaces the branch"; return; fi
      [ "${VERIFY:-}" = success ] || { reason="$VERIFY_CONTEXT is ${VERIFY:-missing}: the sync may add verify failures, so a person merges it"; return; }
      [ "${RENDER:-}" = success ] || { reason="the render is not pure ($RENDER_CONTEXT is ${RENDER:-missing}): an agent-touched sync waits for a person"; return; }
      ok="a pure standards sync, verified and approved, and the required check passed" ;;
    factory)
      has agent:iterate || { reason="no agent:iterate"; return; }
      if [ "${ISSUE_NO_TOUCH:-}" = true ]; then reason="agent:no-touch on the issue"; return; fi
      [ "${TIER:-}" = merge ] || { reason="tier ${TIER:-draft}: a person merges it"; return; }
      # No rebase box here: the loop's update job merges the base into the branch.
      if [ "${MERGEABLE:-}" = dirty ]; then reason="the branch conflicts with its base; the fix loop brings it up to date"; return; fi
      [ "$REVIEW" = success ] || { reason="waits for $REVIEW_CONTEXT to approve (it is ${REVIEW:-missing})"; return; }
      ok="tier merge and approved, and the required check passed" ;;
    *) reason="unknown policy '${POLICY}'"; return ;;
  esac
  if [ "$CHECK" != success ]; then reason="the required check is ${CHECK:-missing}"; return; fi
  if reads_authors && [ -n "${FOREIGN:-}" ]; then reason="a commit is by an author this policy does not merge: $FOREIGN"; return; fi
  if [ -n "$needs_review" ]; then
    case "$REVIEW" in
      success) ;;
      failure) reason="$needs_review: $REVIEW_CONTEXT asks for changes"; return ;;
      '')      reason="$needs_review waits for $REVIEW_CONTEXT, which the head does not have yet"; return ;;
      *)       reason="$needs_review waits for $REVIEW_CONTEXT to approve (it is $REVIEW)"; return ;;
    esac
  fi
  merge=true reason="$ok"
}

# When the rules need a review and the head has none, merge-gate requests one. `agent:review` still on the PR is a request in flight: pr-review clears it.
decide() {
  rules
  review_wanted=false
  if [ -n "$needs_review" ] && [ -z "$REVIEW" ] && ! has agent:review; then review_wanted=true; fi
}

# base_is BRANCH NAME [REASON]: the base must be BRANCH, which NAME describes;
# an unreadable one is a no. REASON replaces the reason for another branch.
base_is() {
  if [ -z "${BASE_REF:-}" ] || [ -z "$1" ]; then reason="the base or $2 could not be read"; return 1; fi
  [ "$BASE_REF" = "$1" ] || { reason="${3:-the base is $BASE_REF, not $2 $1}"; return 1; }
}

# The author rule: not for backmerge (its parent rule replaces it) or hotfix (a
# person may write the patch; the lane and the review stand in).
reads_authors() { case "$POLICY" in backmerge|hotfix) return 1 ;; esac; }

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
          decide; printf 'merge=%s\nrebase=%s\nreview-wanted=%s\nkind=%s\nreason=%s\n' "$merge" "$rebase" "$review_wanted" "$kind" "$reason"; exit 0 ;;
esac

: "${REPO:?}" "${PR:?}" "${SHA:?}" "${POLICY:?}" "${REQUIRED_CHECK:?}"
labels=$(jq -r '.[]' <<<"$LABELS")
CHECK='' REVIEW='' FOREIGN='' TIER='' ISSUE_NO_TOUCH='' AGE='' MERGEABLE="${MERGEABLE:-}"
HEAD_REF="${HEAD_REF:-}" BASE_REF="${BASE_REF:-}" DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
PARENTS='' P1_REL='' P2_REL='' LANE='' LANE_REASON='' VERIFY='' RENDER=''
AUTHOR="${AUTHOR:-}" APP_BOT="${APP_BOT:-}"
# A standards sync allows the org App alone as a commit author.
[ "$POLICY" != standards-sync ] || ALLOWED_AUTHORS="$APP_BOT"

# Reads every input the policy can use. The kill switch is the first rule, so
# with it off nothing is read.
read_inputs() {
  # deps, backmerge, hotfix (through target-guard) and standards-sync compare the
  # base with the default branch. pr-facts hands it over from the call that read
  # the PR; only an empty value is read here.
  if [ "$POLICY" != factory ] && [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=$(gh api "/repos/$REPO" --jq '.default_branch' 2>/dev/null || true)
  fi
  # backmerge: the head's parents, read only when the cheap rules still hold. A
  # parent is an ancestor of a branch when compare `parent...branch` is `identical`
  # or `ahead`; anything else, or a failed read, is not.
  if [ "$POLICY" = backmerge ] && [[ $HEAD_REF == chore/backmerge-?* ]] && [ -n "$DEFAULT_BRANCH" ] && [ "$BASE_REF" = "$DEFAULT_BRANCH" ]; then
    PARENT_SHAS=$(gh api "/repos/$REPO/commits/$SHA" --jq '.parents[].sha' 2>/dev/null || true)
    PARENTS=$(grep -c . <<<"$PARENT_SHAS" || true)
    if [ "$PARENTS" = 2 ]; then
      rel_of() { gh api "/repos/$REPO/compare/$1...$2" --jq '.status' 2>/dev/null || true; }
      P1_REL=$(rel_of "$(sed -n 1p <<<"$PARENT_SHAS")" "$BASE_REF")
      P2_REL=$(rel_of "$(sed -n 2p <<<"$PARENT_SHAS")" "$RELEASE_BRANCH")
    fi
  fi
  # hotfix: target-guard's own verdict, derived again from the live PR rather than
  # read from a PR Checks run that may be older than the head. pr-facts found an
  # open same-repo PR, so not a fork. A base that is not the release branch is
  # routed to `skip` before the guard reads anything.
  if [ "$POLICY" = hotfix ]; then
    guard=$(EVENT=pull_request REPO="$REPO" NUMBER="$PR" BASE="$BASE_REF" HEAD="$HEAD_REF" FORK=false TITLE="${TITLE:-}" \
              AUTHOR="$AUTHOR" RELEASE_BRANCH="$RELEASE_BRANCH" DEFAULT_BRANCH="$DEFAULT_BRANCH" "$HERE/../target-guard/guard.sh" verdict)
    LANE=$(sed -n 's/^verdict=//p' <<<"$guard") LANE_REASON=$(sed -n 's/^reason=//p' <<<"$guard")
  fi
  # factory: the issue the PR closes, its kill switch and its tier. Implement
  # writes `Closes #n` itself, so this reads our own output. No issue is draft.
  if [ "$POLICY" = factory ] && has agent:iterate; then
    ISSUE=$(gh api "/repos/$REPO/pulls/$PR" --jq '.body // ""' 2>/dev/null \
              | grep -oiE '(closes|fixes|resolves) #[0-9]+' | sed -n 1p | grep -oE '[0-9]+' || true)
    if [ -n "$ISSUE" ]; then
      if gh api "/repos/$REPO/issues/$ISSUE/labels?per_page=100" --jq '[.[].name]' 2>/dev/null | grep -q '"agent:no-touch"'; then
        ISSUE_NO_TOUCH=true
      fi
      TIER=$(REPO="$REPO" ISSUE="$ISSUE" GITHUB_OUTPUT=/dev/null "$HERE/../factory/factory.sh" fields | sed -n 's/^tier=//p')
    fi
  fi
  # Each read only when the labels and the cheap rules leave something to decide:
  # most refusals need none.
  needs_evidence() {
    case "$POLICY" in
      backmerge) ;;
      hotfix) [ "$LANE" = lane ] ;;
      standards-sync) [ "$HEAD_REF" = "$SYNC_BRANCH" ] && [ -n "$APP_BOT" ] && [ "$AUTHOR" = "$APP_BOT" ] ;;
      *) has deps:verified || has deps:fixed || [ -n "$TIER" ] ;;
    esac
  }
  if needs_evidence; then
    # The newest run of the required check on the head commit; a re-run replaces it.
    CHECK=$(gh api "/repos/$REPO/commits/$SHA/check-runs?check_name=$(jq -rn --arg n "$REQUIRED_CHECK" '$n|@uri')" \
              --jq '.check_runs | sort_by(.id) | last | (.conclusion // .status // empty)' 2>/dev/null || true)
    # A commit whose author GitHub cannot map has no login and counts as foreign.
    ! reads_authors || FOREIGN=$(gh api "/repos/$REPO/pulls/$PR/commits?per_page=100" --paginate --jq '.[] | (.author.login // "unknown")' \
                | sort -u | grep -vxF -f <(tr ',' '\n' <<<"$ALLOWED_AUTHORS") | tr '\n' ' ' || true)
    FOREIGN="${FOREIGN% }"
    # One read of the head's statuses; decide uses what its policy needs.
    STATUSES=$(gh api "/repos/$REPO/commits/$SHA/status" --jq '[.statuses[] | {context, state}]' 2>/dev/null || echo '[]')
    state_of() { jq -r --arg c "$1" '[.[] | select(.context == $c)][0].state // empty' <<<"$STATUSES" 2>/dev/null || true; }
    REVIEW=$(state_of "$REVIEW_CONTEXT")
    AGE=$(state_of "$AGE_CONTEXT")
    VERIFY=$(state_of "$VERIFY_CONTEXT")
    RENDER=$(state_of "$RENDER_CONTEXT")
  fi
}
[ "${KILL:-}" = false ] || read_inputs
decide
{
  echo "merge=$merge"
  echo "rebase=$rebase"
  echo "review-wanted=$review_wanted"
  echo "kind=$kind"
  echo "reason=$reason"
} >> "$GITHUB_OUTPUT"
echo "#$PR at $SHA: kind=$kind base=${BASE_REF:-unknown}/${DEFAULT_BRANCH:-unknown} parents=${PARENTS:-none}/${P1_REL:-none}/${P2_REL:-none} check=${CHECK:-missing} review=${REVIEW:-missing} age=${AGE:-none} mergeable=${MERGEABLE:-unknown} foreign=${FOREIGN:-none} tier=${TIER:-none} lane=${LANE:-none} verify=${VERIFY:-none} render=${RENDER:-none} author=${AUTHOR:-unknown}"
echo "merge=$merge: $reason"
