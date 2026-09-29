#!/usr/bin/env bash
# What a release run gets from install.sh: semantic-release on PATH with every
# default plugin, a caller's checkout left exactly as it was, and a real
# `--dry-run` from a directory that has no node_modules of its own. That last
# check is the one that matters. A plugin or a preset found only because it
# sat in the checkout would fail here and pass everywhere else.
#
# Needs the network (npm ci). Run from anywhere: ./actions/release-tooling/test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/release-tooling-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

prefix="$tmp/prefix"
export GITHUB_PATH="$tmp/path" GITHUB_ENV="$tmp/env"
: > "$GITHUB_PATH"; : > "$GITHUB_ENV"

"$here/install.sh" "$here" "$prefix"

grep -qx "$prefix/node_modules/.bin" "$GITHUB_PATH" \
  || { echo "FAIL: semantic-release's bin directory is not on PATH"; exit 1; }
grep -q "^NODE_PATH=$prefix/node_modules" "$GITHUB_ENV" \
  || { echo "FAIL: NODE_PATH does not name the prefix"; exit 1; }

# The cache-hit path: a second call reuses the tree and installs nothing.
touch "$prefix/node_modules/.marker"
"$here/install.sh" "$here" "$prefix"
[ -f "$prefix/node_modules/.marker" ] || { echo "FAIL: a second run reinstalled over a ready prefix"; exit 1; }

# A caller's checkout: a manifest with a dependency, and a repo with one
# releasable commit. Nothing may be added to it by the tooling.
work="$tmp/work"
remote="$tmp/remote.git"
mkdir -p "$work"
cd "$work"
cat > package.json <<'JSON'
{ "name": "consumer", "version": "1.0.0", "private": true, "dependencies": { "left-pad": "1.3.0" } }
JSON
# A CommonJS config that require()s a plugin package by name, as some callers'
# configs do. It resolves through NODE_PATH, and only there.
cat > .releaserc.js <<'JS'
require("conventional-changelog-conventionalcommits");
module.exports = {
  branches: ["main"],
  plugins: [
    ["semantic-release-scope-filter", { scopes: ["app"], filterOutMissingScope: true }],
    ["@semantic-release/commit-analyzer", { preset: "conventionalcommits" }],
    ["@semantic-release/release-notes-generator", { preset: "conventionalcommits" }],
    ["@semantic-release/changelog", { changelogFile: "CHANGELOG.md" }],
    ["@semantic-release/exec", { prepareCmd: "true" }],
    ["@semantic-release/git", { assets: ["CHANGELOG.md"] }],
  ],
};
JS
git init -q -b main .
git config user.name test
git config user.email test@example.com
git init -q --bare -b main "$remote"
git remote add origin "file://$remote"
git add -A
git commit -q -m "feat(app): first"
git push -q origin main

before=$(git status --porcelain | shasum)
PATH="$prefix/node_modules/.bin:$PATH" NODE_PATH="$prefix/node_modules" \
  semantic-release --dry-run --no-ci > "$tmp/out" 2>&1 \
  || { cat "$tmp/out"; echo "FAIL: semantic-release did not run"; exit 1; }
grep -q "Published release 1.0.0" "$tmp/out" \
  || { cat "$tmp/out"; echo "FAIL: semantic-release found no release in a feat commit"; exit 1; }

[ ! -e node_modules ] || { echo "FAIL: the run created a node_modules in the checkout"; exit 1; }
[ "$(git status --porcelain | shasum)" = "$before" ] \
  || { echo "FAIL: the run changed the checkout"; exit 1; }

# A caller that names its own packages gets exactly those.
custom="$tmp/custom"
"$here/install.sh" "$here" "$custom" "semantic-release@25 @semantic-release/changelog"
[ -x "$custom/node_modules/.bin/semantic-release" ] || { echo "FAIL: custom install has no semantic-release"; exit 1; }
[ -d "$custom/node_modules/@semantic-release/changelog" ] || { echo "FAIL: custom install lost a requested package"; exit 1; }

echo "PASS: release tooling installs outside the checkout and runs"
