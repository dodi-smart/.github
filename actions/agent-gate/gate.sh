#!/usr/bin/env bash
# The gate, as a standalone script so it can be tested without a runner.
#
# Reads its inputs from the environment and writes proceed/reason/mode to
# $GITHUB_OUTPUT. action.yml is a thin wrapper around this file; test.sh runs it
# directly. Keeping the logic out of YAML is what makes the kill switch
# something we can actually assert on (see test.sh).
set -euo pipefail

stop() {
  {
    echo "proceed=false"
    echo "reason=$1"
    echo "mode="
  } >> "$GITHUB_OUTPUT"
  echo "gate: STOP — $1"
  exit 0
}
go() {
  {
    echo "proceed=true"
    echo "reason=$1"
    echo "mode=${2:-}"
  } >> "$GITHUB_OUTPUT"
  echo "gate: PROCEED — $1${2:+ (mode: $2)}"
  exit 0
}

# ------------------------------------------------------------------
# RULE 0 — the kill switch. First, always, with no exemption: not for
# workflow_dispatch, not for an explicit command, not for a maintainer.
# A kill switch that works on only some code paths is not a kill
# switch (DODI-00008). Do not move this below anything.
# ------------------------------------------------------------------
if printf '%s' "$LABELS" | grep -q '"agent:no-touch"'; then
  stop "agent:no-touch"
fi

# RULE 1 — drafts. Nothing is ready to be judged yet.
if [ "$SKIPDRAFT" = "true" ] && [ "$DRAFT" = "true" ]; then
  stop "draft"
fi

# RULE 2 — bot authors. `reject` keeps human-review workflows off
# Renovate PRs (deps-verify owns those, and covering both double-posts).
# `only` is the inverse, for deps-verify itself.
is_bot=false
if printf '%s' "$AUTHOR" | grep -qiE 'renovate|dependabot|\[bot\]$'; then
  is_bot=true
fi
case "$BOTS" in
  reject) [ "$is_bot" = "true" ] && stop "bot author: $AUTHOR" ;;
  only)   [ "$is_bot" = "true" ] || stop "not a bot dependency PR" ;;
  allow)  : ;;
  *)      echo "::error::unknown bots value '$BOTS' (expected reject|only|allow)"; exit 1 ;;
esac

# RULE 3 — docs-only. Passed in rather than computed, because the
# caller already has the diff and a second checkout is not free.
if [ -n "${FILES:-}" ]; then
  if ! printf '%s\n' "$FILES" | grep -qvE '(\.md$|^docs/)'; then
    stop "docs only"
  fi
fi

# RULE 4 — a `labeled` event proceeds ONLY for this workflow's request
# label. Without this, adding any label at all re-runs the whole thing.
if [ "$ACTION" = "labeled" ]; then
  if [ -n "$REQUEST" ] && [ "$LABEL" = "$REQUEST" ]; then
    go "requested by label: $LABEL"
  fi
  stop "labeled '$LABEL' — only $REQUEST requests this workflow"
fi

# RULE 5 — comment commands, as `@claude <verb>`. The verb list is an
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
