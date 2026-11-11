#!/usr/bin/env bash
# The org's hooks for every agent run, installed as a managed settings drop-in.
#
# Every run passes `--settings '{"disableAllHooks":true}'` to keep a repo's own
# hooks out (see the header in action.yml). Claude Code never lets that flag
# turn off a managed hook, so hooks the org installs here still run.
#
# Reads AGENT_HOOKS, a JSON object shaped like a settings file's `hooks`: event
# names, each with a list of matcher groups. Only that object is written, under
# `hooks`, so the variable cannot set a permission or any other managed key.
# Writes `file`, the drop-in's path, or empty when there is none.
#
# The drop-in lives in /etc, so this needs Linux and passwordless sudo, which
# hosted runners have. Anywhere else the run goes on without the hooks and says
# so. MANAGED_DIR replaces the directory for tests.
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"
dir="${MANAGED_DIR:-/etc/claude-code/managed-settings.d}"
file=''

hooks="${AGENT_HOOKS:-}"
if [ -n "${hooks//[[:space:]]/}" ]; then
  if ! doc=$(jq -ce 'select(type == "object" and all(.[]; type == "array")) | {hooks: .}' <<<"$hooks" 2>/dev/null); then
    echo "::error title=Agent hooks refused::AGENT_HOOKS is not a JSON object of hook events, each with a list of matcher groups."
    exit 1
  fi
  file="$dir/50-agent-hooks.json"
  sudo=''
  if [ -z "${MANAGED_DIR:-}" ]; then
    if [ "$(uname -s)" = Linux ] && sudo -n true 2>/dev/null; then sudo='sudo'
    else
      echo "::warning title=Agent hooks skipped::Installing the org's hooks needs Linux and passwordless sudo; this run goes on without them."
      file=''
    fi
  fi
  if [ -n "$file" ]; then
    $sudo install -d -m 0755 "$dir" && printf '%s\n' "$doc" | $sudo tee "$file" > /dev/null && $sudo chmod 0644 "$file"
    echo "agent hooks: $(jq -r '.hooks | keys | join(" ")' <<<"$doc")"
  fi
fi
echo "file=$file" >> "$GITHUB_OUTPUT"
