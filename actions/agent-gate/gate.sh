#!/usr/bin/env bash
# The gate as a standalone script, so test.sh can run it without a runner.
# It reads its inputs from the environment and writes its outputs to $GITHUB_OUTPUT.
set -euo pipefail

stop() {
  {
    echo "proceed=false"
    echo "reason=$1"
    echo "mode="
  } >> "$GITHUB_OUTPUT"
  echo "gate: STOP: $1"
  exit 0
}
# A re-run replays the event payload, so an `agent:no-touch` added since is
# missed. Before any run proceeds, read the item's labels once; a failed read only warns.
live_no_touch() {
  local live number="${NUMBER:-}"
  if [ -z "$number" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
    number="$(jq -r '.issue.number // .pull_request.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  fi
  [ -n "$number" ] || return 0
  if live="$(gh api "/repos/${REPO:?REPO is required}/issues/$number/labels?per_page=100" --jq '[.[].name]' 2>/dev/null)"; then
    if printf '%s' "$live" | grep -q '"agent:no-touch"'; then
      stop "agent:no-touch (added after the event)"
    fi
  else
    echo "::warning title=agent-gate::could not read the live labels of #$number, so agent:no-touch was judged from the event payload only"
  fi
}
go() {
  live_no_touch
  {
    echo "proceed=true"
    echo "reason=$1"
    echo "mode=${2:-}"
  } >> "$GITHUB_OUTPUT"
  echo "gate: PROCEED: $1${2:+ (mode: $2)}"
  exit 0
}

# The one place that says who is a bot. Every workflow reads `author-kind`
# instead of keeping its own list, so a new dependency bot is one edit here.
# Written before every rule below, the kill switch included, so it is set on a
# stopped run too. That lets a caller use the gate for classification alone.
# It only labels the author; it decides nothing.
#   dependency  Renovate or Dependabot, in the `[bot]` and gh CLI `app/` forms
#   agent       claude[bot], the org's own agent
#   automation  any other bot, such as github-actions[bot] or an org app
#   human       everything else
DEPENDENCY_BOTS='renovate[bot],dependabot[bot],app/renovate,app/dependabot'
login="$(printf '%s' "${AUTHOR:-}" | tr '[:upper:]' '[:lower:]')"
if [ -z "$login" ]; then
  kind=human
else
  case ",$DEPENDENCY_BOTS," in
    *",$login,"*) kind=dependency ;;
    *) case "$login" in
         'claude[bot]'|app/claude) kind=agent ;;
         *'[bot]'|app/*)           kind=automation ;;
         *)                        kind=human ;;
       esac ;;
  esac
fi
{
  echo "author-kind=$kind"
  echo "dependency-bots=$DEPENDENCY_BOTS"
} >> "$GITHUB_OUTPUT"

# ------------------------------------------------------------------
# RULE 0, the kill switch. First, always, with no exemption. Not for
# workflow_dispatch, not for an explicit command, not for a
# maintainer. A kill switch that works on only some paths is not a
# kill switch. Do not move this below anything.
# ------------------------------------------------------------------
if printf '%s' "${LABELS:-}" | grep -q '"agent:no-touch"'; then
  stop "agent:no-touch"
fi

# RULE 0b, the event allow-list. Empty means any event. A workflow whose
# caller listens to more events than it can act on names the ones it can, so a
# person's PR review never reaches an issue agent. It sits after the kill
# switch and can only stop a run, never start one.
if [ -n "${EVENTS:-}" ]; then
  # shellcheck disable=SC2153  # EVENT and EVENTS are two inputs, not a typo
  case " $EVENTS " in
    *" $EVENT "*) : ;;
    *) stop "event $EVENT is not one this workflow handles ($EVENTS)" ;;
  esac
fi

# RULE 1, drafts. Nothing is ready to be judged yet.
if [ "$SKIPDRAFT" = "true" ] && [ "$DRAFT" = "true" ]; then
  stop "draft"
fi

# RULE 2, bot authors. `reject` keeps human-review workflows off
# Renovate PRs (deps-verify owns those, and covering both double-posts).
# `only` is the inverse, for deps-verify itself — and it means DEPENDENCY
# bots, not any bot. claude[bot] authors PRs too, and a generic [bot]
# match sent one of those through deps-verify, where a "verify this
# dependency PR" prompt with no lockfile diff produced no verdict file
# and failed the job.
case "$BOTS" in
  reject) [ "$kind" = "human" ] || stop "bot author: $AUTHOR" ;;
  only)   [ "$kind" = "dependency" ] || stop "not a dependency-bot PR (author: $AUTHOR)" ;;
  allow)  : ;;
  *)      echo "::error::unknown bots value '$BOTS' (expected reject|only|allow)"; exit 1 ;;
esac

# RULE 3, docs-only. Passed in rather than computed, because the
# caller already has the diff and a second checkout is not free.
if [ -n "${FILES:-}" ]; then
  if ! printf '%s\n' "$FILES" | grep -qvE '(\.md$|^docs/)'; then
    stop "docs only"
  fi
fi

# RULE 4, a `labeled` event proceeds ONLY for this workflow's request
# label. Without this, adding any label at all re-runs the whole thing.
if [ "$ACTION" = "labeled" ]; then
  if [ -n "$REQUEST" ] && [ "$LABEL" = "$REQUEST" ]; then
    go "requested by label: $LABEL"
  fi
  stop "labeled '$LABEL', only $REQUEST requests this workflow"
fi

# RULE 5, the general assistant. Proceeds on a bare mention, and DECLINES
# the verbs another workflow owns.
#
# This is the inverse of RULE 6 and the reason both live here. Every repo used
# to hand-maintain this exclusion in its own claude.yml, twice, once per job,
# and keep it in sync with the triage caller's verb list by hand. It had already
# drifted: one repo guarded pull_request_review_comment and the other did not.
# One list, one place; adding a verb is one commit instead of one per repo.
if [ -n "${MENTION:-}" ]; then
  printf '%s' "$COMMENT" | grep -qF "$MENTION" || stop "no $MENTION in the body"
  for verb in ${EXCLUDE:-}; do
    if printf '%s' "$COMMENT" | grep -qiE "${MENTION}[[:space:]]+${verb}\b"; then
      stop "reserved command '$verb', another workflow owns it"
    fi
  done
  go "mentioned: $MENTION"
fi

# RULE 6, comment commands, as `@claude <verb>`. The verb list is an
# input so it lives in ONE place; it used to be hand-copied into every
# repo's claude.yml and had already drifted between two of them.
if [ "$EVENT" = "issue_comment" ] && [ -n "${COMMANDS:-}" ]; then
  for verb in $COMMANDS; do
    if printf '%s' "$COMMENT" | grep -qiE "@claude[[:space:]]+$verb\b"; then
      go "requested by comment: @claude $verb" "$verb"
    fi
  done
  stop "comment did not name a command for this workflow"
fi

go "$EVENT${ACTION:+/$ACTION}"
