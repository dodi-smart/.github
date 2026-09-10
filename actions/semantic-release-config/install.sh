#!/usr/bin/env bash
# Make @dodi-smart/semantic-release-config resolvable from a consuming repo
# without a registry.
#
# The package is never published. It lives in this repo, is fetched at @v1
# with the rest of the actions, and is linked into the consumer's
# node_modules by name. Its plugin dependencies are installed in a private
# prefix, never in the checkout this script was fetched with, so nothing that
# shares that checkout loses a dependency. The package's exports carry each
# plugin as an absolute path into that prefix, so whichever config names it
# and however that config was loaded, the pinned copy is the one that runs.
# The consumer's own package manager never sees any of it: no package.json
# change, no lockfile change, nothing to bump.
#
# Usage: install.sh <repo-root-of-this-checkout> [consumer-dir]
# Env:   SEMANTIC_RELEASE_CONFIG_PREFIX  where to install (default: a fresh
#        directory under RUNNER_TEMP or TMPDIR). Reused when it already holds
#        an install, which is what makes a second run cheap.
set -euo pipefail

root=$1
consumer=${2:-$PWD}
name=@dodi-smart/semantic-release-config

[ -f "$root/semantic-release/index.js" ] || { echo "::error::no shared config at $root/semantic-release"; exit 1; }

prefix=${SEMANTIC_RELEASE_CONFIG_PREFIX:-$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/semantic-release-config.XXXXXX")}
mkdir -p "$prefix/semantic-release"

# The lockfile is the workspace root's, so the prefix mirrors that shape:
# root manifests plus the workspace directory. Production dependencies only.
# --ignore-scripts: nothing here needs a lifecycle script, and the checkout
# is not the consumer's trust boundary.
cp "$root/package.json" "$root/package-lock.json" "$prefix/"
cp "$root/semantic-release/index.js" "$root/semantic-release/package.json" "$prefix/semantic-release/"
# In a subshell with the prefix as cwd: `npm ci --prefix` does not reliably
# read the prefix's own manifests and named the root after the directory.
(cd "$prefix" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null)

target="$consumer/node_modules/$name"
mkdir -p "$(dirname "$target")"
rm -rf "$target"
ln -s "$prefix/semantic-release" "$target"

# Prove it resolves the way semantic-release will use it: by name from the
# consumer, with its plugins coming from the prefix and not from the consumer.
# shellcheck disable=SC2016 # the template literals are JavaScript, not shell
node --input-type=module -e '
  import { createRequire } from "node:module";
  import { realpathSync } from "node:fs";
  const [name, consumer, given] = process.argv.slice(1);
  const prefix = realpathSync(given);
  const req = createRequire(consumer + "/");
  const entry = req.resolve(name);
  const generator = "@semantic-release/release-notes-generator";
  const resolved = createRequire(entry).resolve(generator);
  if (!resolved.startsWith(prefix + "/")) throw new Error(`${generator} resolved outside the prefix: ${resolved}`);
  const dir = resolved.slice(0, resolved.lastIndexOf(generator) + generator.length);
  const { version } = req(dir + "/package.json");
  console.log(`${name} -> ${entry}`);
  console.log(`${generator} ${version} from ${dir}`);
' -- "$name" "$consumer" "$prefix"
