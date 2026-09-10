// Shared semantic-release configuration for this org.
//
// Never published. actions/semantic-release-config links this directory into
// a consumer's node_modules by name, with the plugins below installed beside
// it, and the shared release workflow runs that action before semantic-release.
//
// Two ways to use it.
//
//   1. Extend it whole, when the repo is a single package released from `main`
//      with `develop` as a prerelease channel:
//
//        // .releaserc.json
//        { "extends": "@dodi-smart/semantic-release-config" }
//
//   2. Compose, when the repo needs its own plugin list (a version file to
//      rewrite, a scope filter, several modules). Every plugin comes from an
//      export here, never as a bare package name:
//
//        // release.config.mjs
//        import { branches, commitAnalyzer, releaseNotes, changelog, git, github }
//          from "@dodi-smart/semantic-release-config";
//        export default {
//          branches,
//          plugins: [commitAnalyzer(), releaseNotes(), changelog, git({ assets: ["pubspec.yaml", "CHANGELOG.md"] }), github],
//        };
//
// Every plugin this file names is a dependency of this package, so a consumer
// installs `semantic-release` and this package and nothing else.
//
// The exports carry each plugin as an ABSOLUTE PATH, resolved from this file,
// not as a package name. semantic-release loads a plugin named in a config
// from its own directory first, so a bare name resolves to the copy
// semantic-release depends on, whatever the consumer installed, and the
// `extends` mechanism that redirects that only covers plugins the extended
// config itself lists, and is bypassed entirely by `--extends <file>` on the
// command line. A path has none of those conditions: whatever config names it,
// however it was loaded, the plugin this package pins is the one that runs.
// `pluginName()` maps a path back to its package name for logs and tests.
// `test/e2e.test.mjs` runs real dry runs over consumer configs, through the
// installer, to hold that line.
//
// A note on `effect`, because it is the trap that produced this package.
// conventional-changelog-conventionalcommits v10 replaced the boolean `hidden`
// property on a type with `effect: "hidden" | "bump"`. It does not warn on the
// old key: a type still carrying `hidden: true` is treated as `bump`, so every
// `docs:` and `chore:` commit lands in the notes as an untitled bullet. The
// tests in `test/` hold the rendered output byte-for-byte against the v9
// baseline, so a regression there fails loudly.

import { fileURLToPath } from "node:url";

const names = new Map();

/**
 * The absolute path of a plugin this package depends on, so that whichever
 * config names it and however that config was loaded, this copy runs. See the
 * note at the top of this file.
 */
export function plugin(name) {
  const path = fileURLToPath(import.meta.resolve(name));
  names.set(path, name);
  return path;
}

/** The package name behind a plugin entry, for logs and assertions. */
export function pluginName(entry) {
  const ref = Array.isArray(entry) ? entry[0] : entry;
  return names.get(ref) ?? ref;
}

/** Branch model every repo in the org shares. */
export const branches = ["main", { name: "develop", prerelease: true, channel: "develop" }];

/**
 * What each commit type releases. Anything not listed falls through to the
 * preset, which bumps on `feat`, `fix`, `perf` and `revert` and on nothing
 * else, so the explicit `release: false` rows are documentation as much as
 * policy.
 */
export const releaseRules = [
  { type: "feat", release: "minor" },
  { type: "fix", release: "patch" },
  { type: "perf", release: "patch" },
  { type: "revert", release: "patch" },
  { type: "refactor", release: "patch" },
  { type: "docs", release: false },
  { type: "style", release: false },
  { type: "test", release: false },
  { type: "build", release: false },
  { type: "ci", release: false },
  { breaking: true, release: "major" },
];

/**
 * Changelog sections. The preset takes the FIRST entry whose type (and scope,
 * when given) matches a commit, so an override must be listed before the entry
 * it overrides; `releaseNotes()` puts extras first for that reason.
 */
export const types = [
  { type: "feat", section: "✨ Features", effect: "bump" },
  { type: "fix", section: "🐛 Bug Fixes", effect: "bump" },
  { type: "perf", section: "⚡ Performance Improvements", effect: "bump" },
  { type: "revert", section: "⏪ Reverts", effect: "bump" },
  { type: "docs", section: "📚 Documentation", effect: "bump" },
  { type: "style", section: "💄 Styles", effect: "bump" },
  { type: "refactor", section: "♻️ Code Refactoring", effect: "bump" },
  { type: "test", section: "✅ Tests", effect: "bump" },
  { type: "build", section: "📦 Build System", effect: "bump" },
  { type: "ci", section: "👷 Continuous Integration", effect: "bump" },
  { type: "chore", section: "🔧 Miscellaneous Chores", effect: "hidden" },
];

/** The release commit. `[skip ci]` so the commit does not re-trigger CI. */
export const commitMessage = "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}";

/**
 * Merge override rules into the shared list. A rule with the same type and
 * scope REPLACES the shared one rather than sitting beside it, because the
 * analyzer treats a `release: false` match as undecided and lets a later
 * matching rule win, so an override could otherwise never switch a shared
 * rule off. Rules with no shared twin go first.
 */
function mergeRules(shared, extra) {
  const key = (r) => `${r.type ?? ""}(${r.scope ?? ""})${r.breaking ? "!" : ""}`;
  const overridden = new Set(extra.map(key));
  return [...extra, ...shared.filter((r) => !overridden.has(key(r)))];
}

/**
 * @param {{ releaseRules?: object[] }} [overrides] rules merged over the
 *   shared ones, see `mergeRules`. An extra `chore(deps) -> patch` adds a
 *   rule; an extra `refactor -> false` replaces the shared `refactor` rule.
 */
export function commitAnalyzer({ releaseRules: extra = [] } = {}) {
  return [
    plugin("@semantic-release/commit-analyzer"),
    { preset: "conventionalcommits", releaseRules: mergeRules(releaseRules, extra) },
  ];
}

/**
 * Merge override entries into the shared list without disturbing its order,
 * because the writer emits sections in list order and a prepended override
 * would put its section ahead of Features.
 *
 * An entry with the same type and scope replaces the shared one in place. A
 * scoped entry with no shared twin, `chore(deps)` say, goes directly before
 * the bare entry of its type so that the first match still wins. Anything
 * else is appended.
 */
function mergeTypes(shared, extra) {
  const merged = shared.map((t) => ({ ...t }));
  for (const entry of extra) {
    const same = merged.findIndex((t) => t.type === entry.type && (t.scope ?? null) === (entry.scope ?? null));
    if (same !== -1) {
      merged[same] = { ...merged[same], ...entry };
      continue;
    }
    const bare = merged.findIndex((t) => t.type === entry.type && !t.scope);
    merged.splice(bare === -1 ? merged.length : bare, 0, { ...entry });
  }
  return merged;
}

/**
 * @param {{ types?: object[] }} [overrides] section entries merged over the
 *   shared ones, see `mergeTypes`. Use `effect`, never `hidden`; see the note
 *   at the top of this file.
 */
export function releaseNotes({ types: extra = [] } = {}) {
  return [
    plugin("@semantic-release/release-notes-generator"),
    {
      preset: "conventionalcommits",
      presetConfig: { types: mergeTypes(types, extra) },
      writerOpts: { commitsSort: ["scope", "subject"] },
    },
  ];
}

export const changelog = [plugin("@semantic-release/changelog"), { changelogFile: "CHANGELOG.md" }];

/**
 * Bumps `version` in package.json without publishing. It rewrites the file
 * whether or not the package is the thing being released, so it is part of
 * the default config only because that config is for Node packages; a repo
 * with an incidental package.json composes and leaves it out.
 */
export const npm = [plugin("@semantic-release/npm"), { npmPublish: false }];

/** Run shell commands at release steps. Pass the `*Cmd` options yourself. */
export const exec = plugin("@semantic-release/exec");

/**
 * @param {{ assets?: string[] }} [overrides] files to commit with the release.
 *   Globs, and a name that matches nothing is simply skipped, which is why the
 *   default can name every lockfile the org uses.
 */
export function git({ assets = ["package.json", "bun.lock", "package-lock.json", "pnpm-lock.yaml", "CHANGELOG.md"] } = {}) {
  return [plugin("@semantic-release/git"), { assets, message: commitMessage }];
}

/**
 * @param {{ releasedLabels?: string[] | false }} [overrides] labels for every
 *   issue and PR the release closes. The default names `release:prod` or
 *   `release:staging`; pass `false` in a repo without those labels.
 */
export function github({ releasedLabels = ["release:<%= nextRelease.channel ? 'staging' : 'prod' %>"] } = {}) {
  return [plugin("@semantic-release/github"), { releasedLabels }];
}

/** Merge `main` back into `develop` after a release, opening a PR when it conflicts. */
export const backmerge = [
  plugin("@kilianpaquier/semantic-release-backmerge"),
  {
    commit: "chore(release): merge branch ${ from } into ${ to } [skip ci]",
    targets: [{ from: "main", to: "develop" }],
    title: "Automatic merge failure",
  },
];

/**
 * The whole config for a Node package released from `main` with `develop` as
 * a prerelease channel. Order matters: `changelog` and `npm` prepare files
 * that `git` then commits, and `backmerge` runs last so it merges the release
 * commit rather than the one before it. A repo that is not a Node package
 * composes instead, because `npm` rewrites whatever package.json it finds.
 */
export default {
  branches,
  plugins: [commitAnalyzer(), releaseNotes(), changelog, npm, git(), github(), backmerge],
};
