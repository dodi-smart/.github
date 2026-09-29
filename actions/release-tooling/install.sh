#!/usr/bin/env bash
# Install the semantic-release tooling in a private prefix and put it on PATH.
#
# The prefix is never the caller's checkout. `npm install <pkg>` there also
# resolves and installs everything in the caller's package.json, which cost
# about a minute and a half of every release run for tooling the release does
# not need, and could fail on a peer conflict in a tree the release never
# uses. It also wrote into the caller's tree, where a lockfile does harm.
#
# With no packages this installs the versions pinned in this directory's
# lockfile. With packages (a caller's own `semantic-release-packages`) it
# installs exactly those, unpinned, as it always did.
#
# Usage: install.sh <this-directory> <prefix> [packages]
# Env:   GITHUB_PATH, GITHUB_ENV  written when set, so later steps find the
#        `semantic-release` binary and a CommonJS release config can still
#        `require()` a plugin by name.
set -euo pipefail

here=$1
prefix=$2
packages=${3:-}

# A restored cache holds the marker, so a hit skips the install entirely.
if [ ! -f "$prefix/.ready" ]; then
  mkdir -p "$prefix"
  if [ -z "$packages" ]; then
    cp "$here/package.json" "$here/package-lock.json" "$prefix/"
    # --ignore-scripts: nothing pinned here needs a lifecycle script.
    (cd "$prefix" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null)
  else
    # In a subshell with the prefix as cwd, as semantic-release-config does:
    # `--prefix` does not reliably pick up the prefix's own manifest.
    printf '{"private":true}\n' > "$prefix/package.json"
    # Unquoted on purpose: a space-separated list of package specs.
    # shellcheck disable=SC2086
    (cd "$prefix" && npm install --no-audit --no-fund $packages >/dev/null)
  fi
  touch "$prefix/.ready"
fi

echo "$prefix/node_modules/.bin" >> "${GITHUB_PATH:-/dev/null}"
# semantic-release finds its own plugins from its own directory, so this is
# only for a config that require()s one. NODE_PATH covers CommonJS, not ESM.
echo "NODE_PATH=$prefix/node_modules${NODE_PATH:+:$NODE_PATH}" >> "${GITHUB_ENV:-/dev/null}"
