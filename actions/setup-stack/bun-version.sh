#!/usr/bin/env bash
# Decide which bun to install, from what the repo already pins.
#
# CI used to take `latest` while the repo pinned another bun, so a frozen
# install failed whenever the two lockfile formats differed. `auto` (or empty)
# reads the repo's own pin from the current directory, in this order:
#   package.json packageManager "bun@x.y.z", .bun-version, .tool-versions,
#   mise.toml, .mise.toml
# An explicit version, `latest` included, is used as given. Nothing found means
# `latest`, with a notice.
#
# oven-sh/setup-bun accepts an exact version or a range but not a leading `v`,
# so that is stripped here.
#
# Usage: bun-version.sh <bun-version input>
# Writes version= and source= to $GITHUB_OUTPUT.
set -euo pipefail

requested="${1:-}"

first_version() { # first word, without a leading v
  local v="${1%%[[:space:]]*}"
  printf '%s' "${v#v}"
}

from_package_json() {
  [ -f package.json ] || return 0
  sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([^"+]*\).*/\1/p' package.json | head -n 1
}
from_bun_version() {
  [ -f .bun-version ] || return 0
  first_version "$(head -n 1 .bun-version | tr -d '\r')"
}
from_tool_versions() {
  [ -f .tool-versions ] || return 0
  # `bun 1.2.3 [fallback ...] # comment`: the first version listed wins.
  first_version "$(sed -n 's/^[[:space:]]*bun[[:space:]][[:space:]]*\([^#]*\).*/\1/p' .tool-versions | head -n 1)"
}
from_mise() { # only `bun = "x"` under [tools]
  [ -f "$1" ] || return 0
  awk '
    /^[[:space:]]*\[/ { in_tools = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*(#.*)?$/); next }
    in_tools && match($0, /^[[:space:]]*"?bun"?[[:space:]]*=[[:space:]]*["\047][^"\047]+["\047]/) {
      s = substr($0, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", s); sub(/["\047]$/, "", s)
      print s; exit
    }' "$1"
}

version=""; from=""
if [ -n "$requested" ] && [ "$requested" != auto ]; then
  version="$requested"; from="input"
else
  for candidate in package.json .bun-version .tool-versions mise.toml .mise.toml; do
    case "$candidate" in
      package.json)   v="$(from_package_json)" ;;
      .bun-version)   v="$(from_bun_version)" ;;
      .tool-versions) v="$(from_tool_versions)" ;;
      *)              v="$(from_mise "$candidate")" ;;
    esac
    if [ -n "$v" ]; then version="$v"; from="$candidate"; break; fi
  done
  if [ -z "$version" ]; then
    version="latest"; from="none"
    echo "::notice::This repo pins no bun version (packageManager, .bun-version, .tool-versions, mise.toml), so CI installs the latest bun."
  fi
fi

echo "bun version: $version (from $from)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "version=$version"; echo "source=$from"; } >> "$GITHUB_OUTPUT"
fi
