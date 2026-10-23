// Run a plugin's `prepare` on a stable release only.
//
// A prerelease commits nothing. `changelog`, `npm` and `git` exist to write a
// release into the repository: a changelog entry, a version bump, a commit.
// On the prerelease branch that commit lands on the integration branch, where
// it rewrites the same version lines the next stable release rewrites on the
// release branch, so the back-merge between them conflicts on every release.
// A prerelease still gets its tag, its notes and its GitHub prerelease; what
// it no longer gets is a commit, so the integration branch never touches the
// version lines and the back-merge has nothing to conflict on.
//
// This module is a semantic-release plugin that wraps another one. It is
// configured with the wrapped plugin's absolute path beside that plugin's own
// options:
//
//   [stableOnlyPath, { plugin: "/abs/path/to/plugin.js", changelogFile: "CHANGELOG.md" }]
//
// `verifyConditions` always runs, so a bad configuration fails on every branch
// and not only on the first stable release. `prepare` runs when the release is
// stable and is skipped, with one log line saying why, when it is not. This
// entry carries those two lifecycles, which is all `changelog` and `git` have.
// `stable-only-publish.js` carries `publish` and `addChannel` as well, for
// `npm`. Each lifecycle a wrapper entry carries is delegated unchanged; a
// plugin that lacks one gets a no-op.
//
// The wrapped plugin is an absolute path for the reason `plugin()` in
// `index.js` gives: a bare name resolves from semantic-release's own directory
// and would load whichever copy that finds.

import { isAbsolute } from "node:path";
import { pathToFileURL } from "node:url";

const loaded = new Map();

/** Import a plugin by absolute path the way semantic-release does: a CommonJS-style default wins over named exports. */
async function load(path) {
  if (!loaded.has(path)) {
    loaded.set(
      path,
      import(pathToFileURL(path).href).then(({ default: cjsExport, ...named }) => cjsExport ?? named),
    );
  }
  return loaded.get(path);
}

/** Split the wrapper's configuration into the wrapped plugin and the options that are the wrapped plugin's own. */
async function unwrap(pluginConfig) {
  const { plugin, ...options } = pluginConfig ?? {};
  if (typeof plugin !== "string" || !isAbsolute(plugin)) {
    throw new Error(
      `stable-only: "plugin" must be the absolute path of the wrapped plugin, got ${JSON.stringify(plugin)}. ` +
        "A bare name resolves from semantic-release's own directory, which is the copy this package exists to avoid.",
    );
  }
  return [await load(plugin), options];
}

/**
 * Why a release is not stable, or `undefined` when it is. A prerelease branch
 * and a release on a channel are both integration releases. A maintenance
 * branch also carries a channel (semantic-release names it after the branch)
 * but its releases are stable, and the changelog entry and version bump of a
 * stable release belong in the repository.
 */
export function skipReason({ branch, nextRelease } = {}) {
  if (branch?.prerelease) return `branch "${branch.name}" is a prerelease branch`;
  if (nextRelease?.channel && branch?.type !== "maintenance") return `the release is on channel "${nextRelease.channel}"`;
  return undefined;
}

const delegate = (step) => async (pluginConfig, context) => {
  const [wrapped, options] = await unwrap(pluginConfig);
  return wrapped[step]?.(options, context);
};

/**
 * The lifecycles of a wrapper entry. Every call returns fresh functions:
 * semantic-release stamps a `pluginName` on each function it loads, and two
 * entries must not share one.
 *
 * @param {string[]} [extra] lifecycles delegated unchanged beyond
 *   `verifyConditions` and `prepare`.
 */
export function lifecycles(extra = []) {
  const steps = { verifyConditions: delegate("verifyConditions") };
  for (const step of extra) steps[step] = delegate(step);
  steps.prepare = async (pluginConfig, context) => {
    const reason = skipReason(context);
    if (reason) {
      context.logger.log(`Skip prepare: ${reason}`);
      return undefined;
    }
    return delegate("prepare")(pluginConfig, context);
  };
  return steps;
}

export const { verifyConditions, prepare } = lifecycles();
