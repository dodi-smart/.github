#!/usr/bin/env bash
# The org's additions to every agent run: plugins on top of the caller's, and
# environment variables for the agent alone. Both come from org settings, so
# this public repo names no tool they serve.
#
# Reads PLUGINS, MARKETPLACES (the caller's), ORG_PLUGINS, ORG_MARKETPLACES,
# AGENT_ENV (plain KEY=VALUE lines, from an org variable) and AGENT_ENV_SECRET
# (the same, from an org secret; its values are masked, and its line wins when
# both name a key). Writes `plugins` and `marketplaces` (newline-separated) and
# `settings`, the path of a claude-code-action settings file carrying the env,
# or empty when there is none.
#
# The env goes only into the agent's settings, never into GITHUB_ENV, so the
# deterministic steps after the agent never see it. A key that would change how
# the runner, the action or the agent's credentials behave is refused.
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"

lines() { printf '%s\n' "$@" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | awk '!seen[$0]++' || true; }
multi() { { echo "$1<<__AGENT_ENV_EOF__"; [ -z "$2" ] || printf '%s\n' "$2"; echo "__AGENT_ENV_EOF__"; } >> "$GITHUB_OUTPUT"; }

multi plugins      "$(lines "${PLUGINS:-}" "${ORG_PLUGINS:-}")"
multi marketplaces "$(lines "${MARKETPLACES:-}" "${ORG_MARKETPLACES:-}")"

refused() {
  case "$1" in
    GITHUB_*|RUNNER_*|ACTIONS_*|INPUT_*|ANTHROPIC_*|CLAUDE_CODE_*|LD_*|DYLD_*) return 0 ;;
    PATH|HOME|SHELL|GH_TOKEN|NODE_OPTIONS|BASH_ENV|ENV|PYTHONPATH|GIT_*) return 0 ;;
  esac
  return 1
}

env_json='{}'
parse() { # <text> <secret: true|false> <name, for errors>
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    if [ "$key" = "$line" ] || ! [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "::error title=Agent env line refused::a line in ${3} is not KEY=VALUE."
      exit 1
    fi
    if refused "$key"; then
      echo "::error title=Agent env key refused::$key in ${3} would change the runner, the action or the agent's credentials."
      exit 1
    fi
    [ "$2" = true ] && [ -n "$value" ] && echo "::add-mask::$value"
    env_json=$(jq -c --arg k "$key" --arg v "$value" '.[$k] = $v' <<<"$env_json")
  done <<<"$1"
}
parse "${AGENT_ENV:-}" false AGENT_ENV
parse "${AGENT_ENV_SECRET:-}" true AGENT_ENV_SECRET

settings=''
if [ "$env_json" != '{}' ]; then
  settings="${RUNNER_TEMP:?}/agent-settings.json"
  ( umask 077; jq -n --argjson e "$env_json" '{env: $e}' > "$settings" )
  echo "agent env: $(jq -r 'keys | join(" ")' <<<"$env_json")"
fi
echo "settings=$settings" >> "$GITHUB_OUTPUT"
