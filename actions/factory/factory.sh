#!/usr/bin/env bash
# The deterministic half of the agent factory: everything that decides, pushes,
# marks ready or merges. Agents only write files and local commits. This script
# reads fields and statuses and acts on them, and test.sh runs it without a
# runner, with `gh` stubbed.
#
#   factory.sh tier     MODE RISK EFFORT        -> tier=merge|ready|draft
#   factory.sh branch   TYPE NUM TITLE          -> branch=<feat|fix|chore>/<n>-<slug>
#   factory.sh fields   (REPO, ISSUE)           -> state, mode, risk, effort, priority, tier
#   factory.sh push     (env, see push())       -> pushed, refused, sha (round 0)
#   factory.sh holdout  (BASE_SHA, ISSUE)       -> refuse-paths for a fix round,
#                                                  merge-refuse-paths for a merge round
#   factory.sh decide   (env, see decide())     -> action and the facts behind it
#   factory.sh sweep    (REPO)                  -> dirty=<numbers of agent PRs that conflict>
#
# Outputs go to $GITHUB_OUTPUT as key=value lines, and are echoed for the log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The identity every factory commit carries. claude-code-action commits as this
# by default, and the push step writes each round as it whatever the agent used.
FACTORY_NAME='claude[bot]'
FACTORY_EMAIL='41898282+claude[bot]@users.noreply.github.com'
HOLDOUT_DIR='.factory/holdout.d'   # one list per issue
HOLDOUT='.factory/holdout'         # the old shared list, read only
# The commit status pr-review writes its verdict to: success approve, failure changes.
REVIEW_CONTEXT='review / verdict'

out() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; printf '%s=%s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# tier: the autonomy ladder. The first row that matches wins, and anything
# unset or unknown is `draft`, the tier that changes nothing.
#   Autonomous, Risk Low, Effort Low                       -> merge
#   Autonomous, Risk Low|Medium, Effort Low|Medium         -> ready
#   everything else                                        -> draft
# ---------------------------------------------------------------------------
tier_of() {
  local mode="$1" risk="$2" effort="$3"
  if [ "$mode" != Autonomous ]; then echo draft; return; fi
  if [ "$risk" = Low ] && [ "$effort" = Low ]; then echo merge; return; fi
  case "$risk/$effort" in
    Low/Medium|Medium/Low|Medium/Medium) echo ready ;;
    *) echo draft ;;
  esac
}

# ---------------------------------------------------------------------------
# branch: a conventional name from the issue type and title. A bug is fix/,
# a feature or improvement is feat/, anything else chore/.
# ---------------------------------------------------------------------------
branch_of() {
  local type="$1" num="$2" title="$3" prefix slug
  case "$type" in
    Bug) prefix=fix ;;
    Feature|Improvement) prefix=feat ;;
    *) prefix=chore ;;
  esac
  slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')
  [ -n "$slug" ] || slug=issue
  echo "$prefix/$num-$slug"
}

# ---------------------------------------------------------------------------
# fields: read the issue's single-select fields, repo-scoped (the App has no
# org permission). A read that fails leaves every field unset.
# ---------------------------------------------------------------------------
read_fields() {
  local owner="${REPO%%/*}" name="${REPO##*/}" values
  # shellcheck disable=SC2016  # $o/$r/$n are GraphQL variables, not shell
  if values=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
    repository(owner:$o,name:$r){ issue(number:$n){
      issueFieldValues(first:50){ nodes{
        ... on IssueFieldSingleSelectValue {
          name field { ... on IssueFieldSingleSelect { name } } } } } } } }' \
    -f o="$owner" -f r="$name" -F n="$ISSUE" \
    --jq '[.data.repository.issue.issueFieldValues.nodes[] | select(.field.name != null)]' 2>/dev/null); then
    F_READ=true
  else
    values='[]'; F_READ=false
  fi
  get() { jq -r --arg f "$1" '.[]|select(.field.name==$f)|.name' <<<"$values" | head -1; }
  F_STATE=$(get "Triage state"); F_MODE=$(get "Agent mode"); F_RISK=$(get "Risk"); F_EFFORT=$(get "Effort")
  F_PRIORITY=$(get "Priority")
}

# ---------------------------------------------------------------------------
# lint_only: true when every job that failed in the PR Checks run failed only
# in `hk check --all`, so the fix is lint or format. The aggregate job named
# PR Checks fails whenever another job does, so it is left out. A failed job
# with no failed step (a timeout, a cancel) is not lint.
# ---------------------------------------------------------------------------
lint_only() {
  [ -n "${1:-}" ] || { echo false; return; }
  gh api --paginate "/repos/$REPO/actions/runs/$1/jobs?per_page=100" --jq '.jobs[]' 2>/dev/null \
    | jq -s '[.[] | select(.conclusion == "failure" and (.name | test("(^|/ )PR Checks$") | not))
              | [.steps[]? | select(.conclusion == "failure") | .name]]
             | length > 0 and all(length > 0 and all(. == "hk check --all"))' 2>/dev/null || echo false
}

# ---------------------------------------------------------------------------
# push: write implement's commits as round 0, ONE commit, to a new branch.
# Fix rounds go through actions/push-round, which pushes to an existing one.
#
# env: BASE_SHA (head before the agent), HEAD_REF, REPO, APP_TOKEN, ISSUE,
#      SUBJECT (used only when it is a conventional commit header),
#      AGENT_EMAILS (newline-separated authors the agent may commit as)
#
# Refused, never forced, when: no App token, a commit carries another author,
# or the branch already exists.
# ---------------------------------------------------------------------------
push_round() {
  local new others subject first url
  git reset -q --hard HEAD   # uncommitted edits are not part of a round
  echo "pushed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  new=$(git rev-list --count "$BASE_SHA..HEAD")
  if [ "$new" = 0 ]; then echo "no commits"; out refused "the agent committed nothing"; return 0; fi
  refuse() { out refused "$1"; echo "::warning title=Round not pushed::$1"; exit 0; }

  others=$(git log --format='%ae' "$BASE_SHA..HEAD" | grep -vxF -f <(printf '%s\n%s\n' "$FACTORY_EMAIL" "${AGENT_EMAILS:-}" | sed '/^$/d') || true)
  [ -n "$others" ] && refuse "a commit carries another author: $(printf '%s' "$others" | paste -sd ' ' -)"

  first=$(git log --reverse --format='%s' "$BASE_SHA..HEAD" | head -n 1)
  subject="${SUBJECT:-}"
  printf '%s' "$subject" | grep -qE '^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)(\([a-z0-9._/-]+\))?!?: [^ ].{0,100}$' \
    || subject="$first"
  local trailers="Factory-Round: 0"
  [ -z "${ISSUE:-}" ] || trailers="$trailers
Factory-Issue: $ISSUE"
  # The agent's own trailers ride after the round's; push-round owns the rule.
  local kept
  kept=$("$HERE/../push-round/round.sh" trailers)
  [ -z "$kept" ] || trailers="$trailers
$kept"
  git reset -q --soft "$BASE_SHA"
  GIT_COMMITTER_NAME="$FACTORY_NAME" GIT_COMMITTER_EMAIL="$FACTORY_EMAIL" \
    git commit -q --author="$FACTORY_NAME <$FACTORY_EMAIL>" -m "$subject" -m "$trailers"
  out sha "$(git rev-parse HEAD)"

  [ -z "${APP_TOKEN:-}" ] && refuse "GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks"
  url="https://x-access-token:${APP_TOKEN}@github.com/${REPO}.git"
  [ -n "$(git ls-remote "$url" "refs/heads/$HEAD_REF" | cut -f1)" ] && refuse "branch $HEAD_REF already exists"
  git push -q "$url" "HEAD:refs/heads/$HEAD_REF"
  out pushed true
}

# ---------------------------------------------------------------------------
# holdout: the paths a fix round may not touch, as an ERE for push-round's
# refuse-paths. Only the PR's own issue counts: every file .factory/holdout.d/
# $ISSUE lists at BASE_SHA, and the list. A PR opened before the lists moved
# has none, so it gets the lines its round-0 commit added to the old shared
# list, and that file; drop this once no such PR is open. No ISSUE: the old file.
# ---------------------------------------------------------------------------
holdout_paths() {
  local issue="${ISSUE:-}" list="$HOLDOUT" body='' c
  if [ -n "$issue" ] && body=$(git show "$BASE_SHA:$HOLDOUT_DIR/$issue" 2>/dev/null); then
    list="$HOLDOUT_DIR/$issue"
  elif [ -n "$issue" ]; then
    # Round 0 is one commit with both trailers; the anchors keep 1 from matching 12.
    c=$(git log -1 --format=%H --all-match --grep='^Factory-Round: 0$' --grep="^Factory-Issue: $issue\$" "$BASE_SHA" 2>/dev/null || true)
    [ -z "$c" ] || body=$(git diff --no-renames --unified=0 "$c^" "$c" -- "$HOLDOUT" 2>/dev/null \
                          | awk '/^@@/ { h = 1; next } h && /^\+/ { print substr($0, 2) }' || true)
  fi
  printf '^(%s)$' "$(printf '%s\n' "$body" "$list" \
    | sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's/[][\.^$*+?(){}|]/\\&/g' | paste -sd '|' -)"
}

# ---------------------------------------------------------------------------
# mergeable_of: the PR's mergeable_state, `dirty` whenever `mergeable` is
# false (a draft reads `draft`, conflict or not). GitHub computes it on first
# read, so a fresh answer is `unknown`: read once more after a short wait.
# Still unknown is no conflict. Args: PR number, the PR json already read.
# ---------------------------------------------------------------------------
MERGEABLE_Q='if .mergeable == false then "dirty" else .mergeable_state // "unknown" end'
mergeable_reread() { gh api "/repos/$REPO/pulls/$1" --jq "$MERGEABLE_Q" 2>/dev/null || echo unknown; }
mergeable_of() {
  local s
  s=$(jq -r "$MERGEABLE_Q" <<<"$2")
  if [ "$s" = unknown ]; then
    sleep "${MERGEABLE_WAIT:-5}"
    s=$(mergeable_reread "$1")
  fi
  printf '%s' "${s:-unknown}"
}

# The PRs the fix loop never touches, for `decide` and `sweep` alike: a fork, an
# agent:no-touch label, a dependency bot's PR (deps-verify and deps-automerge own
# those; the loop would push agent commits onto a branch Renovate rebases, and
# judge a tier with no issue behind it, so a hand-added label stops here).
# skip_reason PR_JSON NUMBER -> the reason on stdout, or nothing when the PR is the loop's.
skip_reason() {
  local json="$1" pr="$2"
  if [ "$(jq -r '.head.repo.full_name != .base.repo.full_name' <<<"$json")" != false ]; then
    echo "#$pr is from a fork"
  elif jq -e '[(.labels // [])[].name] | index("agent:no-touch")' >/dev/null <<<"$json"; then
    echo "agent:no-touch on #$pr"
  elif [ "$("$HERE/../agent-gate/gate.sh" kind "$(jq -r '.user.login // ""' <<<"$json")")" = dependency ]; then
    echo "#$pr is a dependency-bot PR; deps-verify owns it, not the fix loop"
  fi
}

# ---------------------------------------------------------------------------
# decide: what the fix loop does next for one PR. Reads everything live, so a
# re-run decides from the state now, never from the event that started it.
#
# env: REPO, PR (may be empty), EVENT_SHA (the commit the event was about; may be
#      empty), MAX_ROUNDS
#
# MERGEABLE_WAIT: seconds to wait before the one re-read of a mergeable state
#      GitHub has not computed yet (default 5)
#
# action: stop | update | fix-ci | fix-review | ready | review | land | handoff | give-up
#   update is a PR GitHub reports as conflicting with its base: no PR Checks run
#   on it, so no event would ever reach the loop. It is judged before the checks.
# ---------------------------------------------------------------------------
decide() {
  local pr="${PR:-}" json state draft labels head base body issue rounds checks run_id verdict tier skip
  finish() { out action "$1"; out reason "$2"; exit 0; }

  if [ -z "$pr" ] && [ -n "${EVENT_SHA:-}" ]; then
    pr=$(gh api "/repos/$REPO/commits/$EVENT_SHA/pulls" \
           --jq "[.[] | select(.state == \"open\" and .head.sha == \"$EVENT_SHA\")][0].number // empty" 2>/dev/null || true)
  fi
  [ -n "$pr" ] || finish stop "no open pull request for ${EVENT_SHA:-this event}"
  out number "$pr"

  json=$(gh api "/repos/$REPO/pulls/$pr") || finish stop "could not read #$pr"
  state=$(jq -r .state <<<"$json"); draft=$(jq -r .draft <<<"$json")
  labels=$(jq -c '[.labels[].name]' <<<"$json")
  head=$(jq -r .head.sha <<<"$json"); base=$(jq -r .base.ref <<<"$json")
  body=$(jq -r '.body // ""' <<<"$json")
  out head-sha "$head"; out head-ref "$(jq -r .head.ref <<<"$json")"; out base-ref "$base"

  [ "$state" = open ] || finish stop "#$pr is $state"
  skip=$(skip_reason "$json" "$pr")
  [ -z "$skip" ] || finish stop "$skip"
  grep -q '"agent:iterate"' <<<"$labels" || finish stop "#$pr does not carry agent:iterate"
  if [ -n "${EVENT_SHA:-}" ] && [ "$EVENT_SHA" != "$head" ]; then
    finish stop "the event was for $EVENT_SHA, and #$pr has moved to $head"
  fi

  # The issue the PR closes. Implement writes `Closes #n` itself, so this is a
  # read of our own output, not a guess at a person's wording.
  issue=$(printf '%s' "$body" | grep -oiE '(closes|fixes|resolves) #[0-9]+' | head -n 1 | grep -oE '[0-9]+' || true)
  out issue "${issue:-}"
  F_STATE=''; F_MODE=''; F_RISK=''; F_EFFORT=''; F_PRIORITY=''
  if [ -n "$issue" ]; then
    if gh api "/repos/$REPO/issues/$issue/labels?per_page=100" --jq '[.[].name]' 2>/dev/null | grep -q '"agent:no-touch"'; then
      finish stop "agent:no-touch on issue #$issue"
    fi
    ISSUE="$issue" read_fields
  fi
  tier=$(tier_of "$F_MODE" "$F_RISK" "$F_EFFORT")
  out tier "$tier"
  # The model policy reads these. See actions/pick-model.
  out risk "$F_RISK"; out effort "$F_EFFORT"; out priority "$F_PRIORITY"

  # Every round number on the branch, in commit order: rounds after 0 are fix
  # rounds, and the last one says whether the head is a fix round.
  local nums last
  nums=$(gh api --paginate "/repos/$REPO/pulls/$pr/commits?per_page=100" --jq '.[].commit.message' 2>/dev/null \
           | sed -n 's/^Factory-Round: \([0-9][0-9]*\)$/\1/p' || true)
  rounds=$(printf '%s\n' "$nums" | awk '$1 > 0' | grep -c . || true)
  last=$(printf '%s\n' "$nums" | tail -n 1)
  out rounds "$rounds"

  # Only `dirty` is a conflict; behind, blocked, unstable and a state GitHub has
  # not computed are left to the rules below.
  local mstate
  mstate=$(mergeable_of "$pr" "$json")
  out mergeable-state "$mstate"
  if [ "$mstate" = dirty ]; then
    [ "$rounds" -ge "${MAX_ROUNDS:-3}" ] && finish give-up "the branch conflicts with its base after $rounds fix rounds"
    finish update "the branch conflicts with $base"
  fi

  # PR Checks is the one required context. The caller's job prefixes its name
  # ("<job> / PR Checks"), so match the end. The newest run on the head wins.
  checks=$(gh api "/repos/$REPO/commits/$head/check-runs?per_page=100" \
             --jq '[.check_runs[] | select(.name | test("(^|/ )PR Checks$"))] | sort_by(.started_at) | last // empty
                   | "\(.status) \(.conclusion // "none") \(.details_url // "")"' 2>/dev/null || true)
  run_id=$(printf '%s' "$checks" | grep -oE '/actions/runs/[0-9]+' | grep -oE '[0-9]+' || true)
  out run-id "${run_id:-}"
  verdict=$(gh api "/repos/$REPO/commits/$head/statuses?per_page=100" \
              --jq "[.[] | select(.context == \"$REVIEW_CONTEXT\")][0].state // empty" 2>/dev/null || true)

  # A draft on the ready or merge tier is marked ready unless PR Checks is
  # red. Most callers skip PR Checks on drafts, so waiting for green there
  # would wait forever; ready_for_review starts both checks and review.
  if [ "$draft" = true ] && { [ "$tier" = merge ] || [ "$tier" = ready ]; }; then
    case "$checks" in
      completed\ failure*|completed\ timed_out*) ;;
      *) finish ready "tier $tier, and PR Checks is not red" ;;
    esac
  fi

  case "$checks" in
    '') finish stop "PR Checks has not reported on $head" ;;
    completed\ success*) ;;
    completed\ failure*|completed\ timed_out*)
      [ "$rounds" -ge "${MAX_ROUNDS:-3}" ] && finish give-up "PR Checks is red after $rounds fix rounds"
      # Only a first round can go to the lint model, so later rounds skip the read.
      [ "$rounds" -eq 0 ] && [ "$(lint_only "$run_id")" = true ] && out signals lint-only
      finish fix-ci "PR Checks failed on $head" ;;
    completed*) finish stop "PR Checks ended ${checks#completed } on $head; nothing to fix" ;;
    *) finish stop "PR Checks is still running on $head" ;;
  esac

  [ "$draft" = true ] && finish stop "checks are green; tier draft, so a person marks it ready"
  case "$verdict" in
    success)
      [ "$tier" = merge ] && finish land "checks green and review approved $head"
      finish handoff "review approved $head; tier $tier stops here for a person" ;;
    failure|error)
      [ "$rounds" -ge "${MAX_ROUNDS:-3}" ] && finish give-up "review asked for changes after $rounds fix rounds"
      finish fix-review "review asked for changes on $head" ;;
    pending) finish stop "review is running on $head" ;;
    *)
      # An agent PR is opened by the App, and pr-review reviews a bot's PR
      # only when a bot asks with agent:review, so ready_for_review starts no
      # review. Ask for every head with no verdict, once.
      grep -q '"agent:review"' <<<"$labels" && finish stop "review already requested on #$pr"
      finish review "no review verdict on round ${last:-0}" ;;
  esac
}

# ---------------------------------------------------------------------------
# sweep: the open agent PRs that conflict with their base, as `dirty` numbers.
# It only lists; the caller relays each one to `decide`.
#
# env: REPO, MERGEABLE_WAIT
# Skipped: what `skip_reason` names, the rules `decide` stops on too.
# ---------------------------------------------------------------------------
sweep() {
  local nums n json dirty='' unknown=''
  nums=$(gh api --paginate "/repos/$REPO/issues?state=open&labels=agent:iterate&per_page=100" \
           --jq '.[] | select(.pull_request != null) | .number' 2>/dev/null || true)
  for n in $nums; do
    json=$(gh api "/repos/$REPO/pulls/$n" 2>/dev/null) || continue
    [ -z "$(skip_reason "$json" "$n")" ] || continue
    case "$(jq -r "$MERGEABLE_Q" <<<"$json")" in
      dirty)   dirty="${dirty:+$dirty }$n" ;;
      unknown) unknown="${unknown:+$unknown }$n" ;;
    esac
  done
  # One wait for all of them: the first read started GitHub's computation.
  if [ -n "$unknown" ]; then
    sleep "${MERGEABLE_WAIT:-5}"
    for n in $unknown; do
      [ "$(mergeable_reread "$n")" != dirty ] || dirty="${dirty:+$dirty }$n"
    done
  fi
  out dirty "$dirty"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  tier)   out tier "$(tier_of "${1:-}" "${2:-}" "${3:-}")" ;;
  branch) out branch "$(branch_of "${1:-}" "${2:-}" "${3:-}")" ;;
  fields)
    read_fields
    out read "$F_READ"; out state "$F_STATE"; out mode "$F_MODE"; out risk "$F_RISK"; out effort "$F_EFFORT"
    out priority "$F_PRIORITY"
    out tier "$(tier_of "$F_MODE" "$F_RISK" "$F_EFFORT")" ;;
  push)    push_round ;;
  holdout)
    hp=$(holdout_paths)
    out refuse-paths "$hp"
    # A merge round may not hand-resolve a lockfile either; the list is the one
    # setup-stack and deps-intent share.
    out merge-refuse-paths "($hp)|($(cat "$HERE/../setup-stack/lockfiles.re"))" ;;
  decide) decide ;;
  sweep)  sweep ;;
  *) echo "usage: factory.sh tier|branch|fields|push|holdout|decide|sweep" >&2; exit 2 ;;
esac
