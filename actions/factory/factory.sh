#!/usr/bin/env bash
# The deterministic half of the agent factory: everything that decides, pushes,
# marks ready or merges. Agents only write files and local commits. This script
# reads fields and statuses and acts on them, and test.sh runs it without a
# runner, with `gh` stubbed.
#
#   factory.sh tier     MODE RISK EFFORT        -> tier=merge|ready|draft
#   factory.sh branch   TYPE NUM TITLE          -> branch=<feat|fix|chore>/<n>-<slug>
#   factory.sh fields   (REPO, ISSUE)           -> state, mode, risk, effort, priority, tier
#   factory.sh state    (REPO, ISSUE, STATE)    -> written: Triage state set to STATE, or why not
#   factory.sh push     (env, see push())       -> pushed, refused, record, sha (round 0)
#   factory.sh holdout  (BASE_SHA, ISSUE)       -> refuse-paths for a fix round,
#                                                  merge-refuse-paths for a merge round
#   factory.sh decide   (env, see decide())     -> action and the facts behind it
#   factory.sh sweep    (REPO)                  -> dirty=<numbers of agent PRs that conflict>
#   factory.sh next     (env, see next())       -> action=dispatch|hold, issue, reason
#   factory.sh pick     < FACTS                 -> next's decision from facts already read
#   factory.sh closes   < BODY                  -> the issue number a PR body closes, or nothing
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
# Which status counts is merge-gate's rule, shared: see statuses.sh.
STATUSES_SH="$HERE/../merge-gate/statuses.sh"

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
# org permission). A read that fails leaves every field unset. `next` reads the
# same fields for every open issue, through the same fragment and mapping.
# ---------------------------------------------------------------------------
FIELDS_GQL='issueFieldValues(first:50){ nodes{
  ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } } } }'
# fields: the node's field values as {"Triage state": "Plan ready", ...}
FIELDS_JQ='def fields: [.issueFieldValues.nodes[] | select(.field.name? != null) | {key: .field.name, value: .name}] | from_entries;'
read_fields() {
  local owner="${REPO%%/*}" name="${REPO##*/}" values
  # shellcheck disable=SC2016  # $o/$r/$n are GraphQL variables, not shell
  if values=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
    repository(owner:$o,name:$r){ issue(number:$n){ createdAt title '"$FIELDS_GQL"' } } }' \
    -f o="$owner" -f r="$name" -F n="$ISSUE" \
    --jq "$FIELDS_JQ .data.repository.issue | {fields: fields, created: .createdAt, title} | tojson" 2>/dev/null); then
    F_READ=true
  else
    values='{}'; F_READ=false
  fi
  get() { jq -r --arg f "$1" '.fields[$f] // empty' <<<"$values"; }
  F_STATE=$(get "Triage state"); F_MODE=$(get "Agent mode"); F_RISK=$(get "Risk"); F_EFFORT=$(get "Effort")
  F_PRIORITY=$(get "Priority")
  F_CREATED=$(jq -r '.created // empty' <<<"$values"); F_TITLE=$(jq -r '.title // empty' <<<"$values")
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
# push-round's guard.sh finds a weakened test or a touched gate file (the
# issue's own holdout list excepted, which round 0 must write), or the branch
# already exists.
# ---------------------------------------------------------------------------
push_round() {
  local new others subject first url
  git reset -q --hard HEAD   # uncommitted edits are not part of a round
  echo "pushed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  new=$(git rev-list --count "$BASE_SHA..HEAD")
  # Every refusal also writes `record`, push-round's metadata-only marker, so
  # a refused round 0 is counted the same way as a refused fix round.
  local round_sh="$HERE/../push-round/round.sh"
  refuse() { # KIND WHY [HITS]
    out refused "$2"
    out record "$("$round_sh" record "$1" 0 "${3:-}")"
    echo "::warning title=Round not pushed::$2"; exit 0
  }
  # Committing nothing is no refusal, as in push-round: no record.
  if [ "$new" = 0 ]; then echo "no commits"; out refused "the agent committed nothing"; return 0; fi

  others=$(git log --format='%ae' "$BASE_SHA..HEAD" | grep -vxF -f <(printf '%s\n%s\n' "$FACTORY_EMAIL" "${AGENT_EMAILS:-}" | sed '/^$/d') || true)
  [ -n "$others" ] && refuse author "a commit carries another author: $(printf '%s' "$others" | paste -sd ' ' -)"

  # The same guard as every fix round; push-round owns the rule and its wording.
  local why hits hits_file rc=0 allow=()
  [ -z "${ISSUE:-}" ] || allow=(--allow "^$(printf '%s' "$HOLDOUT_DIR/$ISSUE" | ere_quote)\$")
  hits_file=$(mktemp "${TMPDIR:-/tmp}/guard-hits.XXXXXX")
  why=$(GUARD_HITS="$hits_file" "$HERE/../push-round/round.sh" guard "${allow[@]}" "$BASE_SHA" HEAD) || rc=$?
  hits=$(cat "$hits_file"); rm -f "$hits_file"
  case "$rc" in 0) ;; 1) refuse guard "$why" "$hits" ;; *) refuse guard-error "$why" ;; esac

  first=$(git log --reverse --format='%s' "$BASE_SHA..HEAD" | sed -n 1p)
  subject="${SUBJECT:-}"
  printf '%s' "$subject" | grep -qE '^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)(\([a-z0-9._/-]+\))?!?: [^ ].{0,100}$' \
    || subject="$first"
  local trailers="Factory-Round: 0"
  [ -z "${ISSUE:-}" ] || trailers="$trailers
Factory-Issue: $ISSUE"
  # The agent's own trailers ride after the round's; push-round owns the rule.
  local kept
  kept=$("$round_sh" trailers)
  [ -z "$kept" ] || trailers="$trailers
$kept"
  git reset -q --soft "$BASE_SHA"
  GIT_COMMITTER_NAME="$FACTORY_NAME" GIT_COMMITTER_EMAIL="$FACTORY_EMAIL" \
    git commit -q --author="$FACTORY_NAME <$FACTORY_EMAIL>" -m "$subject" -m "$trailers"
  out sha "$(git rev-parse HEAD)"

  [ -z "${APP_TOKEN:-}" ] && refuse token "GH_APP_CLIENT_ID is not set, and a GITHUB_TOKEN push starts no checks"
  url="https://x-access-token:${APP_TOKEN}@github.com/${REPO}.git"
  [ -n "$(git ls-remote "$url" "refs/heads/$HEAD_REF" | cut -f1)" ] && refuse exists "branch $HEAD_REF already exists"
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
ere_quote() { sed 's/[][\.^$*+?(){}|]/\\&/g'; }
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
    | sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' | ere_quote | paste -sd '|' -)"
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

# closes_of < BODY -> the issue a PR body closes, from the first `Closes #n`
# (or Fixes, Resolves). Implement writes it, so this reads our own output.
closes_of() { grep -oiE '(closes|fixes|resolves) #[0-9]+' | sed -n 1p | grep -oE '[0-9]+' || true; }

# set_state: set the issue's `Triage state` to $STATE. implement moves it off
# `Plan ready` when it starts (`Ready for agent`) and to `Blocked` when a run
# opens no PR, so the dispatcher, which picks only `Plan ready`, never starts an
# issue twice without a person. The field and option ids come from the
# repository (a repo-scoped App token gets 403 on /orgs/*). A failed write warns
# and prints why; it never fails the run that is reporting.
set_state() {
  local want="${STATE:-}" resp ids node fid oid
  warn() { echo "::warning::Could not set Triage state to \"$want\" on #$ISSUE: $1"; out written "false: $1"; }
  # shellcheck disable=SC2016  # GraphQL variables, not shell ones
  resp=$(gh api graphql -F n="$ISSUE" -f o="${REPO%%/*}" -f r="${REPO##*/}" \
    -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ issue(number:$n){ id }
      issueFields(first:50){ nodes{ ... on IssueFieldSingleSelect { id name options{ id name } } } } } }' 2>/dev/null) \
    || { warn "the issue fields could not be read"; return 0; }
  ids=$(jq -r --arg w "$want" '.data.repository as $r | [$r.issueFields.nodes[]? | select(.name == "Triage state")
          | . as $f | .options[]? | select(.name == $w) | "\($r.issue.id) \($f.id) \(.id)"] | first // empty' <<<"$resp" 2>/dev/null) || ids=''
  [ -n "$ids" ] || { warn "the repository has no Triage state option \"$want\""; return 0; }
  read -r node fid oid <<<"$ids"
  gh api graphql -f query="mutation{ setIssueFieldValue(input:{issueId:\"$node\", issueFields:[{fieldId:\"$fid\", singleSelectOptionId:\"$oid\"}]}){ clientMutationId } }" >/dev/null 2>&1 \
    || { warn "the write was refused"; return 0; }
  out written true
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
# notices SINCE [KEEP]: agent spend, read from the one record of it: the
# `Agent run` notice run-agent writes on its job, parsed by run-agent's own
# notice.jq. Prints one {cost, issue, pr} per notice, cost null when the run was
# unpriced (`cost=?`). Fails when any read fails: missing spend is not zero.
#
# The read is narrow. Only the repo's agent workflows are listed: those whose
# newest runs (five, so one that failed to start hides none) call a shared
# workflow that runs an agent (the ones in this repo
# that call run-agent, read from the files the action's checkout carries). Of
# their completed runs created since SINCE (YYYY-MM-DD), only those KEEP, a jq
# condition on the run, accepts are opened, and of those only jobs with
# annotations. KEEP may read values the caller passes in the environment
# through $ENV.
# ---------------------------------------------------------------------------
notices() {
  local keep="${2:-true}" wf ids id newest suites s jobs j
  wf=$(grep -l 'actions/run-agent' "$HERE"/../../.github/workflows/*.yml 2>/dev/null \
         | sed 's|.*/||; s|\.yml$||' | paste -sd '|' -)
  [ -n "$wf" ] || return 1
  ids=$(gh api --paginate "/repos/$REPO/actions/workflows?per_page=100" --jq '.workflows[].id') || return 1
  suites=$(for id in $ids; do
    newest=$(gh api "/repos/$REPO/actions/workflows/$id/runs?per_page=5") || exit 1
    jq -e --arg wf "$wf" 'any(.workflow_runs[].referenced_workflows[]?;
      .path | test("/\\.github/workflows/(" + $wf + ")\\.yml(@|$)"))' <<<"$newest" >/dev/null || continue
    gh api --paginate "/repos/$REPO/actions/workflows/$id/runs?created=%3E%3D$1&status=completed&exclude_pull_requests=true&per_page=100" \
      --jq ".workflow_runs[] | select(.conclusion != \"skipped\" and ($keep)) | .check_suite_id" || exit 1
  done) || return 1
  for s in $suites; do
    jobs=$(gh api --paginate "/repos/$REPO/check-suites/$s/check-runs?per_page=100" \
             --jq '.check_runs[] | select((.output.annotations_count // 0) > 0) | .id') || return 1
    for j in $jobs; do
      gh api --paginate "/repos/$REPO/check-runs/$j/annotations?per_page=100" \
        --jq '.[] | select(.title == "Agent run") | .message' || return 1
    done
  done | jq -Rc -f "$HERE/../run-agent/notice.jq"
}
# tally SELECT < NOTICES -> {usd, runs, unpriced, note} over the notices SELECT
# keeps: usd to the cent, and note the clause that names the unpriced runs, so
# they never read as free. decide and pick both word it from here.
tally() {
  jq -sc "[.[] | select($1)]"' | {usd: ([.[].cost // 0] | add // 0 | . * 100 | round / 100), runs: length,
    unpriced: ([.[] | select(.cost == null)] | length)}
    | .note = (if .unpriced == 0 then "" else "; \(.unpriced) unpriced run\(if .unpriced == 1 then " is" else "s are" end) not in that sum" end)'
}
is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# ---------------------------------------------------------------------------
# decide: what the fix loop does next for one PR. Reads everything live, so a
# re-run decides from the state now, never from the event that started it.
#
# env: REPO, PR (may be empty), EVENT_SHA (the commit the event was about; may be
#      empty), MAX_ROUNDS, APP_BOT (the org App's login, `<app-slug>[bot]`),
#      MAX_COST_USD (the issue's agent spend at which it gives up; empty: no cap)
#
# Before a round (update, fix-ci, fix-review) it gives up at MAX_ROUNDS fix
# rounds, or once the agent spend of the PR's issue (its notices plus the PR's;
# the PR's alone with no issue) reaches MAX_COST_USD. Unpriced runs add nothing
# and the reason names them. A spend it cannot read gives up too (fail closed).
# The cost cap writes no field: it never demotes a tier (DODI-00068).
#
# The verdict is the newest `review / verdict` the org App posted on the head,
# read through merge-gate's statuses.sh. The same context from anyone else is
# no verdict, so it cannot steer the loop; with no APP_BOT none counts.
#
# MERGEABLE_WAIT: seconds to wait before the one re-read of a mergeable state
#      GitHub has not computed yet (default 5)
#
# action: stop | update | fix-ci | fix-review | ready | review | land | handoff | give-up
#   update is a PR GitHub reports as conflicting with its base: no PR Checks run
#   on it, so no event would ever reach the loop. It is judged before the checks.
# ---------------------------------------------------------------------------
decide() {
  local pr="${PR:-}" json state draft labels head ref base body issue rounds checks run_id verdict tier skip
  # note: what capped learnt about spend, carried by every reason after it.
  local note=''
  finish() { out action "$1"; out reason "$2$note"; exit 0; }

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
  ref=$(jq -r .head.ref <<<"$json")
  out head-sha "$head"; out head-ref "$ref"; out base-ref "$base"

  [ "$state" = open ] || finish stop "#$pr is $state"
  skip=$(skip_reason "$json" "$pr")
  [ -z "$skip" ] || finish stop "$skip"
  grep -q '"agent:iterate"' <<<"$labels" || finish stop "#$pr does not carry agent:iterate"
  if [ -n "${EVENT_SHA:-}" ] && [ "$EVENT_SHA" != "$head" ]; then
    finish stop "the event was for $EVENT_SHA, and #$pr has moved to $head"
  fi

  # The issue the PR closes. Implement writes `Closes #n` itself, so this is a
  # read of our own output, not a guess at a person's wording.
  issue=$(printf '%s' "$body" | closes_of)
  out issue "${issue:-}"
  F_STATE=''; F_MODE=''; F_RISK=''; F_EFFORT=''; F_PRIORITY=''; F_CREATED=''; F_TITLE=''
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

  # capped WHY: give up before another round when the round cap or the cost cap
  # is reached. The spend is read only here, before a round that would add to
  # it, and sets `note`, which the round's reason carries.
  # The runs that can hold this issue's notices: those on the PR's branch (review,
  # a labelled round), those titled with the issue (triage, implement, which run
  # on `issues` before the PR exists) or with the PR (a comment on it runs on
  # `issue_comment` with the default branch), and the fix rounds, which run on
  # `workflow_run` with the default branch and no PR on the run, so every one
  # since the PR opened. A spend it cannot read gives up: the cap is a breaker,
  # and a breaker that cannot see fails closed, as the dispatcher does.
  capped() {
    [ "$rounds" -ge "${MAX_ROUNDS:-3}" ] && finish give-up "$1 after $rounds fix rounds"
    local cap="${MAX_COST_USD:-}" since="$F_CREATED" who="issue #$issue" t usd runs over opened
    # shellcheck disable=SC2016  # $ENV is jq's, read inside notices
    local keep='.head_branch == $ENV.KEEP_REF
      or (.display_title != "" and (.display_title == $ENV.KEEP_PR_TITLE or .display_title == $ENV.KEEP_TITLE))
      or (.event == "workflow_run" and .created_at >= $ENV.KEEP_SINCE)'
    [ -n "$cap" ] || return 0
    is_num "$cap" || { note="; max-cost-usd \"$cap\" is not a number, so no cost cap applies"; return 0; }
    opened=$(jq -r '.created_at // ""' <<<"$json")
    [ -n "$issue" ] || { who="#$pr"; since="$opened"; }
    if [ -z "$since" ] || ! t=$(KEEP_REF="$ref" KEEP_PR_TITLE="$(jq -r '.title // ""' <<<"$json")" KEEP_TITLE="$F_TITLE" KEEP_SINCE="$opened" notices "${since%%T*}" "$keep" 2>/dev/null \
         | tally "(.issue != null and .issue == ${issue:-null}) or .pr == $pr"); then
      out breaker cost
      finish give-up "$1, and the agent spend of $who could not be read, so the cost cap cannot be checked"
    fi
    IFS=$'\t' read -r usd runs over note < <(jq -r --argjson c "$cap" '[.usd, .runs, .usd >= $c, .note] | @tsv' <<<"$t")
    if [ "$over" = true ]; then
      out breaker cost
      finish give-up "$1, and $who has spent $usd USD of its $cap USD cap over $runs agent run$([ "$runs" = 1 ] || echo s)"
    fi
    [ -z "$note" ] || note="; $who has spent $usd USD of $cap$note"
  }

  # Only `dirty` is a conflict; behind, blocked, unstable and a state GitHub has
  # not computed are left to the rules below.
  local mstate
  mstate=$(mergeable_of "$pr" "$json")
  out mergeable-state "$mstate"
  if [ "$mstate" = dirty ]; then
    capped "the branch conflicts with its base"
    finish update "the branch conflicts with $base"
  fi

  # PR Checks is the one required context. The caller's job prefixes its name
  # ("<job> / PR Checks"), so match the end. The newest run on the head wins.
  checks=$(gh api "/repos/$REPO/commits/$head/check-runs?per_page=100" \
             --jq '[.check_runs[] | select(.name | test("(^|/ )PR Checks$"))] | sort_by(.started_at) | last // empty
                   | "\(.status) \(.conclusion // "none") \(.details_url // "")"' 2>/dev/null || true)
  run_id=$(printf '%s' "$checks" | grep -oE '/actions/runs/[0-9]+' | grep -oE '[0-9]+' || true)
  out run-id "${run_id:-}"
  verdict=$("$STATUSES_SH" read "$REPO" "$head" | "$STATUSES_SH" app "$REVIEW_CONTEXT" "${APP_BOT:-}" 2>/dev/null || true)

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
      capped "PR Checks is red"
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
      capped "review asked for changes"
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

# ---------------------------------------------------------------------------
# pick: the dispatcher's decision, a pure function of facts. `next` reads the
# facts and test.sh feeds it JSON. The rules, in order, are the README's
# Dispatch section; the kill switch is checked before any fact is read.
#
# facts: {required, cap, ceiling_h, now, budget,
#         spend:  {usd, runs, unpriced, note}         this month's agent spend (tally)
#         prs:    [{number, closes, waiting_since}]   waiting_since: ISO 8601, or null
#         issues: [{number, created, priority, state, mode, labels}]}
# budget: FACTORY_BUDGET_USD, null when unset, which holds (DODI-00068).
# An issue implement already started is no longer `Plan ready` (set_state), so
# it is never picked twice without a person.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $f, $n and the rest are jq variables, not shell
PICK_JQ='
def rank: {"Urgent": 0, "High": 1, "Medium": 2, "Low": 3}[. // ""] // 4;
def median: sort | length as $n
  | if $n == 0 then null elif $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
def hold($r): {action: "hold", reason: $r};
. as $f
| $f.spend as $s
| "\($s.usd) USD of the \($f.budget) USD budget this month\($s.note)" as $spent
| [$f.prs[].closes] as $covered
| def has_pr: .number as $n | $covered | index($n) != null;
  def labelled($l): .labels | index($l) != null;
  [$f.issues[] | select(labelled("agent:implement") and (has_pr | not))] as $inflight
| (($f.prs | length) + ($inflight | length)) as $wip
| ([$f.prs[] | select(.waiting_since != null) | ($f.now - (.waiting_since | fromdateiso8601)) / 3600] | median) as $wait
| {wip: $wip, wait: (if $wait == null then "" else ($wait * 10 | floor) / 10 end),
   spend: $s.usd} as $m
| $m + if $f.budget == null then hold("FACTORY_BUDGET_USD is not set: with no monthly budget nothing is dispatched")
  elif $wip >= $f.cap then hold("\($f.prs | length) agent PRs open and \($inflight | length) issues being implemented: the WIP cap is \($f.cap)")
  elif $wait != null and $wait >= $f.ceiling_h then hold("the median review wait is \($m.wait)h: the ceiling is \($f.ceiling_h)h")
  elif $s.usd >= $f.budget then hold("the agent spend has reached \($spent)")
  else
    [$f.issues[]
      | select(.state == $f.required and .mode == "Autonomous"
               and (labelled("agent:no-touch") | not) and (labelled("agent:implement") | not) and (has_pr | not))]
    | sort_by([(.priority | rank), .created, .number]) | first
    | if . == null then hold("no open issue is \($f.required), Autonomous and untouched")
      else {action: "dispatch", issue: .number,
            reason: "#\(.number) is \($f.required) and Autonomous, Priority \(.priority // "unset"); WIP \($wip) of \($f.cap); spent \($spent)"} end
  end'
# emit DECISION -> the decision's fields as outputs
emit() {
  local k v
  while IFS='=' read -r k v; do out "$k" "$v"; done < <(jq -r '"action=\(.action)", "issue=\(.issue // "")",
    "reason=\(.reason)", "wip=\(.wip)", "review-wait-h=\(.wait)", "spend=\(.spend)"' <<<"$1")
}
pick() { emit "$(jq -c "$PICK_JQ")"; }

# ---------------------------------------------------------------------------
# next: read the facts `pick` decides from, in two GraphQL reads. It only reads;
# the caller applies agent:implement with the App token.
#
# env: REPO, DISPATCH (the FACTORY_DISPATCH variable), WIP_CAP (default 2),
#      WAIT_CEILING_H (default 24), REQUIRED_STATE (default Plan ready, as in
#      issue-implement), APP_BOT (the App's login, `<slug>[bot]`),
#      BUDGET_USD (the FACTORY_BUDGET_USD variable; unset holds before any read),
#      NOW (epoch seconds; the clock by default)
#
# The month's spend is every `Agent run` notice in the repo since the 1st (UTC),
# read last, since it is the costliest read.
#
# An agent PR is an open PR the App opened whose body says `Closes #n`, which
# implement always writes. One waits for review while it is not a draft and no
# person has reviewed it, since it was last marked ready (or opened). The PRs
# alone at the cap hold before the issues are read. A read that fails holds: a
# dispatcher that cannot see the queue adds nothing.
# ---------------------------------------------------------------------------
next() {
  local dispatch="${DISPATCH:-}" cap="${WIP_CAP:-2}" ceil="${WAIT_CEILING_H:-24}" now="${NOW:-}"
  local required="${REQUIRED_STATE:-Plan ready}" budget="${BUDGET_USD:-}"
  finish() { out action hold; out reason "$1"; exit 0; }
  # The kill switch, before any read.
  [ "$dispatch" = true ] || finish "FACTORY_DISPATCH is \"$dispatch\", not \"true\""
  [[ "$cap" =~ ^[0-9]+$ ]] || finish "wip-cap \"$cap\" is not a whole number"
  is_num "$ceil" || finish "review-wait-ceiling \"$ceil\" is not a number of hours"
  [ -n "${APP_BOT:-}" ] || finish "no agent login: the org App is not configured"
  [ -n "$budget" ] || finish "FACTORY_BUDGET_USD is not set: with no monthly budget nothing is dispatched"
  is_num "$budget" || finish "FACTORY_BUDGET_USD \"$budget\" is not a number of USD"
  [ -n "$now" ] || now=$(date +%s)
  # GraphQL names an App by its slug, with no [bot]. Slugs are [a-z0-9-], so it
  # is safe inside the jq programs below.
  local agent="${APP_BOT%\[bot\]}" owner="${REPO%%/*}" name="${REPO##*/}" n prs issues
  # One object per agent PR. The `Closes #n` match is closes_of's, in jq.
  # shellcheck disable=SC2016  # $c is a jq variable, not shell
  local pr_jq='.data.repository.pullRequests.nodes[]
    | select(.author.__typename == "Bot" and .author.login == "@AGENT@")
    | ([(.body // "") | match("(closes|fixes|resolves) #([0-9]+)"; "i")] | first | .captures[1].string) as $c
    | select($c != null)
    | {number, closes: ($c | tonumber),
       waiting_since: (if .isDraft or any(.reviews.nodes[]; .author.__typename != "Bot" and .author.login != "@AGENT@") then null
                       else (.timelineItems.nodes[0].createdAt // .createdAt) end)}
    | tojson'

  # shellcheck disable=SC2016  # $o/$r/$endCursor are GraphQL variables, not shell
  prs=$(gh api graphql --paginate -f query='query($o:String!,$r:String!,$endCursor:String){
    repository(owner:$o,name:$r){ pullRequests(states:OPEN, first:50, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ number isDraft createdAt body author{ __typename login }
        reviews(first:100){ nodes{ author{ __typename login } } }
        timelineItems(itemTypes:[READY_FOR_REVIEW_EVENT], last:1){ nodes{ ... on ReadyForReviewEvent { createdAt } } } } } } }' \
    -f o="$owner" -f r="$name" --jq "${pr_jq//@AGENT@/$agent}" 2>/dev/null) \
    || finish "could not read the open pull requests"
  prs=$(jq -sc . <<<"$prs")
  n=$(jq length <<<"$prs")
  if [ "$n" -ge "$cap" ]; then out wip "$n"; finish "$n agent PRs open: the WIP cap is $cap"; fi

  # shellcheck disable=SC2016  # $o/$r/$endCursor are GraphQL variables, not shell
  issues=$(gh api graphql --paginate -f query='query($o:String!,$r:String!,$endCursor:String){
    repository(owner:$o,name:$r){ issues(states:OPEN, first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ number createdAt labels(first:50){ nodes{ name } } '"$FIELDS_GQL"'
        } } } }' \
    -f o="$owner" -f r="$name" \
    --jq "$FIELDS_JQ .data.repository.issues.nodes[] | fields as \$v
          | {number, created: .createdAt, labels: [.labels.nodes[].name],
             state: \$v[\"Triage state\"], mode: \$v[\"Agent mode\"], priority: \$v[\"Priority\"]}
          | tojson" 2>/dev/null) \
    || finish "could not read the open issues"

  local spend
  spend=$(notices "$(jq -nr --argjson n "$now" '$n | strftime("%Y-%m-01")')" 2>/dev/null | tally true) \
    || finish "could not read this month's agent spend"

  jq -nc --arg q "$required" --argjson cap "$cap" --argjson c "$ceil" --argjson now "$now" \
     --argjson b "$budget" --argjson s "$spend" \
     --argjson prs "$prs" --argjson issues "$(jq -sc . <<<"$issues")" \
     '{required: $q, cap: $cap, ceiling_h: $c, now: $now, budget: $b, spend: $s, prs: $prs, issues: $issues}' | pick
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
  next)   next ;;
  closes) closes_of ;;
  state)  set_state ;;
  pick)   pick ;;
  tally)  tally "${1:-true}" ;;   # test.sh builds pick's spend facts with it
  *) echo "usage: factory.sh tier|branch|fields|state|push|holdout|decide|sweep|next|pick|tally|closes" >&2; exit 2 ;;
esac
