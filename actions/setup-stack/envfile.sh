#!/usr/bin/env bash
# Turn newline-separated KEY=VALUE text (stdin) into a sourceable file.
#
# One parser for both `env` and `build-env`, so the two can never mean different
# things again. Keys are trimmed, blank and `#` lines are skipped, and the split
# is on the FIRST `=` so URLs and base64 survive. `%q` quotes the value, so
# GRADLE_OPTS arrives as one string of flags rather than several words.
#
# Usage: envfile.sh <output-file> < text
set -euo pipefail

file="${1:?usage: envfile.sh <output-file>}"
: > "$file"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

while IFS= read -r line || [ -n "$line" ]; do
  key="$(trim "${line%%=*}")"
  case "$key" in '' | \#*) continue ;; esac
  value=""
  case "$line" in *=*) value="${line#*=}" ;; esac
  printf 'export %s=%q\n' "$key" "$value" >> "$file"
done
