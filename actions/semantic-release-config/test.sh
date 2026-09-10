#!/usr/bin/env bash
# What a consumer gets from install.sh: the package linked by name into an
# empty node_modules, with the pinned plugins resolving from the private
# prefix and not from the consumer. Checked by resolving, not by reading
# install.sh's output, so rewording a log line cannot fail this.
#
# Run from the repo root: ./actions/semantic-release-config/test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/semantic-release-config-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

consumer="$tmp/consumer"
prefix="$tmp/prefix"
mkdir -p "$consumer" "$prefix"

# The checkout itself must come out exactly as it went in, node_modules
# included, or a job that shares the checkout loses what it installed.
snapshot() { { ls -A "$root/node_modules" 2>/dev/null || true; } | sort | shasum; }
before=$(snapshot)

SEMANTIC_RELEASE_CONFIG_PREFIX="$prefix" "$root/actions/semantic-release-config/install.sh" "$root" "$consumer" >/dev/null

[ "$(snapshot)" = "$before" ] \
  || { echo "FAIL: install.sh changed the checkout's own node_modules"; exit 1; }
[ -L "$consumer/node_modules/@dodi-smart/semantic-release-config" ] \
  || { echo "FAIL: no link in the consumer's node_modules"; exit 1; }

# shellcheck disable=SC2016 # JavaScript, not shell
node --input-type=module -e '
  import { createRequire } from "node:module";
  import { realpathSync } from "node:fs";
  const [consumer, given, root] = process.argv.slice(1);
  const prefix = realpathSync(given);
  const req = createRequire(consumer + "/");
  const cfg = await import(req.resolve("@dodi-smart/semantic-release-config"));
  const pinned = req(root + "/semantic-release/package.json").dependencies;
  // Every plugin the package exports is an absolute path into the prefix, and
  // the two pinned betas are the versions package.json names.
  const entries = [...cfg.default.plugins, cfg.exec];
  for (const entry of entries) {
    const path = Array.isArray(entry) ? entry[0] : entry;
    if (!path.startsWith(prefix + "/")) throw new Error(`plugin outside the prefix: ${path}`);
    const name = cfg.pluginName(entry);
    const dir = path.slice(0, path.lastIndexOf(name) + name.length);
    const { version } = req(dir + "/package.json");
    if (pinned[name] === undefined) throw new Error(`${name} is not a dependency of the package`);
    if (/^\d/.test(pinned[name]) && version !== pinned[name]) throw new Error(`${name} is ${version}, package.json pins ${pinned[name]}`);
    console.log(`ok ${name} ${version}`);
  }
' -- "$consumer" "$prefix" "$root"

echo "PASS: shared config links into a consumer"
