# @dodi-smart/semantic-release-config

Shared semantic-release configuration for this org: branch model, release
rules, changelog sections, and the plugin suite pinned to versions that agree
with each other.

## How it reaches a consumer

This package is never published to any registry. It lives in this repo and
reaches a consumer through `actions/semantic-release-config`, which copies
this checkout's root manifests, lockfile and `semantic-release/` into a
private prefix, installs the plugin dependencies there, then links that
prefix's `semantic-release` directory into the consumer's `node_modules` by
name. The checkout the action was fetched with is left untouched, so nothing
sharing that checkout loses a dependency. The shared
`.github/workflows/release.yml` runs that action automatically, before
semantic-release. A repo that hand-rolls its own release job adds one step
instead, after its own install and before semantic-release:

```yaml
- uses: dodi-smart/.github/actions/semantic-release-config@v1
```

A consumer installs `semantic-release` and nothing else. The package arrives
by the link, not by an install, so nothing is added to its `package.json` or
its lockfile.

## Usage

There are two ways to use it once it is linked.

### Extend

For a repo that is a single package released from `main`, with `develop` as
a prerelease channel:

```json
// .releaserc.json
{ "extends": "@dodi-smart/semantic-release-config" }
```

### Compose

For a repo that needs its own plugin list, such as a version file to rewrite,
a scope filter, or several modules. No `extends` line: import the helpers you
want and list them.

```js
// release.config.mjs
import { branches, commitAnalyzer, releaseNotes, changelog, git, github }
  from "@dodi-smart/semantic-release-config";

export default {
  branches,
  plugins: [
    commitAnalyzer(),
    releaseNotes(),
    changelog,
    git({ assets: ["pubspec.yaml", "CHANGELOG.md"] }),
    github(),
  ],
};
```

A consumer never needs to install a plugin this package already names. Every
plugin the config uses is a dependency of this package itself.

Each export hands out its plugin as an absolute path, resolved from inside
this package, not as a bare package name. That is what makes the composed
form work with no `extends`. semantic-release resolves a plugin named in a
config from its own directory first, so a bare name would get whatever copy
semantic-release itself depends on; the `extends` redirect only fixes that
for plugins the extended config lists, and `--extends <file>` on the command
line, the reusable release workflow's `modules` path, replaces the config's
own `extends` entirely. A path sidesteps all three: it names an exact file,
so it resolves the same way regardless of what named it or how that config
was loaded. `pluginName()` maps a path back to its package name for logs and
assertions. Both usage modes, extended and composed, are covered by real dry
runs in `semantic-release/test/e2e.test.mjs`, run through the installer.

`npm` bumps `package.json`'s version and is always in the default config,
because that config is for a Node package. A repo that is not a Node
package, even one with an incidental `package.json`, composes and leaves
`npm` out.

`exec` is a plugin path with no options baked in; pass your own `*Cmd`
entries as `[exec, { successCmd: "..." }]`.

`github()` takes `{ releasedLabels }`. The default names `release:prod` or
`release:staging`; pass `github({ releasedLabels: false })` in a repo without
those labels, or the release fails trying to apply one.

Entries passed to `releaseNotes({ types })` replace the shared entry of the
same type and scope in place, so the section order stays the shared one. A
scoped entry with no shared twin, `chore(deps)` say, goes directly before the
bare entry of its type, because the preset takes the first match.

`commitAnalyzer({ releaseRules })` works the same way: a rule with the same
type and scope replaces the shared rule instead of sitting beside it. The
analyzer treats a `release: false` match as undecided and lets a later
matching rule win, so an override could otherwise never turn a shared rule
off. This repo's own `release.config.mjs` uses exactly that to keep
`refactor` from releasing here, which it never did before.

## The `effect`, not `hidden`, trap

`conventional-changelog-conventionalcommits` v10 replaced the boolean
`hidden` property on a changelog type with `effect: "hidden" | "bump"`. It
does not warn on the old key: a type that still carries `hidden: true` is
silently treated as `bump`, so every `docs:` and `chore:` commit lands in the
release notes as an untitled bullet. Always write `effect`, never `hidden`,
in any `types` override passed to `releaseNotes()`.

## Why the two betas are pinned exact

`@semantic-release/commit-analyzer` and `@semantic-release/release-notes-generator`
are pinned to exact prerelease versions, with no `^` or `~`. The stable
release of `release-notes-generator` (14.x) cannot render a v10 preset. With
preset 10.0 to 10.3 the notes come out as a bare header, no sections and no
commits, and from 10.4 the preset refuses to render and the release fails.
The exact pin gives Renovate, running in this repo, a specific version to
offer the matching stable release from once one ships. A caret range would
make that bump invisible. Renovate opens that upgrade here, someone merges
it, and every consumer picks it up on its next release, the same way any
other change to this package reaches them. Remove the pins, and the
regression test that guards them, once both plugins are stable.

## Running the tests

```sh
npm test -w semantic-release
```

Tests use only `node:test` and `node:assert/strict`, no test framework
dependency. Two of them compare rendered release notes byte-for-byte against
fixture files in `test/fixtures/`. Those fixtures are generated by hand and
checked in; the test suite never regenerates them.
