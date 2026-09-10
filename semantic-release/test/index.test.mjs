// Regression tests for the shared semantic-release config.
//
// conventional-changelog-conventionalcommits v10 changed the preset
// interface in two ways that silently break release notes:
//
//   1. @semantic-release/release-notes-generator 14 (stable) renders a v10
//      preset as empty notes (header only). The 15.0.0-beta.2 pin fixes
//      this; if the beta is ever swapped for the stable release, notes go
//      silently blank.
//   2. v10 replaced the type property `hidden: true` with
//      `effect: "hidden"`. A stale `hidden: true` is treated as `bump`, so
//      `docs:`/`chore:` commits leak into the notes as untitled bullets.
//
// These tests fail loudly if either regression returns.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { generateNotes } from "@semantic-release/release-notes-generator";
import { analyzeCommits } from "@semantic-release/commit-analyzer";
import pkg from "../package.json" with { type: "json" };
import {
  branches,
  types,
  releaseRules,
  commitMessage,
  commitAnalyzer,
  releaseNotes,
  changelog,
  npm,
  git,
  github,
  backmerge,
  exec,
  pluginName,
  default as config,
} from "../index.js";

const here = dirname(fileURLToPath(import.meta.url));

const commit = (hash, message) => ({ hash, message, committerDate: "2026-09-01T00:00:00Z" });

// The exact commit set from the shared spec: one of every relevant type,
// including a breaking change and a revert.
const commits = [
  commit("aaaaaaa1", "feat(api): add thing\n\nBody"),
  commit("bbbbbbb2", "fix(ui): repair widget (#12)"),
  commit("ccccccc3", "chore(deps): update dependency foo to v2"),
  commit("ddddddd4", "chore: tidy"),
  commit("eeeeeee5", "docs: readme"),
  commit("fffffff6", "perf: faster"),
  commit("1111111a", "refactor!: drop old API\n\nBREAKING CHANGE: old API removed"),
  commit("2222222b", "revert: feat(api): add thing"),
];

const baseContext = {
  commits,
  lastRelease: { gitTag: "v1.0.0", version: "1.0.0" },
  nextRelease: { version: "2.0.0", gitTag: "v2.0.0", type: "major" },
  options: { repositoryUrl: "https://github.com/o/r" },
  cwd: process.cwd(),
  env: {},
  logger: { log() {}, error() {}, success() {} },
};

// The rendered date is today's date, which is not the thing under test.
const normalizeDate = (notes) => notes.replace(/\(\d{4}-\d{2}-\d{2}\)/, "(YYYY-MM-DD)");

const readFixture = (name) => readFileSync(resolve(here, "fixtures", name), "utf8");

test("golden: default releaseNotes() matches the recorded fixture", async () => {
  const [, pluginConfig] = releaseNotes();
  const notes = normalizeDate(await generateNotes(pluginConfig, baseContext));
  assert.equal(notes, readFixture("notes.default.md"));
});

test("golden: composed override releaseNotes() matches the recorded fixture", async () => {
  // This is the shape this repo's own release config uses: a chore/deps
  // section, plus docs and refactor folded into the effect: "hidden" set.
  const [, pluginConfig] = releaseNotes({
    types: [
      { type: "chore", scope: "deps", section: "⬆️ Dependencies", effect: "bump" },
      { type: "docs", effect: "hidden" },
      { type: "refactor", effect: "hidden" },
    ],
  });
  const notes = normalizeDate(await generateNotes(pluginConfig, baseContext));
  assert.equal(notes, readFixture("notes.overrides.md"));
});

test("releaseNotes() overrides replace shared entries in place, so section order is the shared one", () => {
  // The writer emits sections in list order. An override that was simply
  // prepended would put Dependencies ahead of Features; one that replaces
  // its shared twin in place keeps the order readers already know.
  const [, pluginConfig] = releaseNotes({
    types: [
      { type: "chore", scope: "deps", section: "⬆️ Dependencies", effect: "bump" },
      { type: "docs", effect: "hidden" },
    ],
  });
  const merged = pluginConfig.presetConfig.types;
  const at = (type, scope) => merged.findIndex((t) => t.type === type && (t.scope ?? null) === (scope ?? null));

  assert.equal(merged.length, types.length + 1, "one new scoped entry, one replaced in place");
  assert.equal(at("docs"), types.findIndex((t) => t.type === "docs"), "docs stays where the shared list puts it");
  assert.deepEqual(merged[at("docs")], { ...types[at("docs")], effect: "hidden" }, "the shared section survives the override");
  assert.ok(at("feat") < at("chore", "deps"), "a new scoped section does not jump ahead of Features");
  assert.equal(at("chore", "deps"), at("chore") - 1, "chore(deps) sits directly before bare chore, so the first match still wins");
});

test("empty-notes guard: default releaseNotes() renders actual sections and commits", async () => {
  const [, pluginConfig] = releaseNotes();
  const notes = await generateNotes(pluginConfig, baseContext);
  assert.match(
    notes,
    /### ✨ Features/,
    "release-notes-generator is rendering the v10 preset as empty notes (header only, no sections)",
  );
  assert.match(
    notes,
    /\* \*\*api:\*\* add thing/,
    "release-notes-generator is rendering the v10 preset as empty notes (no commit lines)",
  );
});

test("hidden-leak guard: chore commits never leak as untitled bullets", async () => {
  const [, pluginConfig] = releaseNotes();
  const notes = await generateNotes(pluginConfig, baseContext);

  assert.doesNotMatch(notes, /tidy/, "a hidden chore commit leaked into the notes");
  assert.doesNotMatch(notes, /update dependency foo/, "a hidden chore(deps) commit leaked into the notes");

  // No bullet line may sit outside a "### " section, except the
  // breaking-change commit line that intentionally follows the note text
  // directly under "### ⚠ BREAKING CHANGES".
  const lines = notes.split("\n");
  let currentSection = null;
  for (const line of lines) {
    if (line.startsWith("### ")) {
      currentSection = line;
      continue;
    }
    if (/^\* /.test(line)) {
      assert.ok(
        currentSection !== null,
        `untitled bullet outside any section: ${JSON.stringify(line)}`,
      );
    }
  }

  // Static shape check: the exported types never use the retired `hidden`
  // key, and every entry declares a valid `effect`.
  for (const entry of types) {
    assert.ok(!("hidden" in entry), `type entry for "${entry.type}" still carries the retired hidden key`);
    assert.ok(
      entry.effect === "bump" || entry.effect === "hidden",
      `type entry for "${entry.type}" has an invalid effect: ${entry.effect}`,
    );
  }
});

test("commitAnalyzer(): release type per commit set", async () => {
  const analyze = async (releaseRulesOverride, commitSet) => {
    const [, pluginConfig] = commitAnalyzer(releaseRulesOverride);
    return analyzeCommits(pluginConfig, { ...baseContext, commits: commitSet });
  };

  assert.equal(await analyze(undefined, commits), "major");
  assert.equal(await analyze(undefined, [commit("a", "feat: add thing")]), "minor");
  assert.equal(await analyze(undefined, [commit("a", "fix: repair thing")]), "patch");
  assert.equal(await analyze(undefined, [commit("a", "refactor: reshape thing")]), "patch");
  assert.equal(await analyze(undefined, [commit("a", "docs: readme")]), null);
  assert.equal(await analyze(undefined, [commit("a", "chore: tidy")]), null);
  assert.equal(await analyze(undefined, [commit("a", "chore(deps): bump foo")]), null);

  const withDepsRule = { releaseRules: [{ type: "chore", scope: "deps", release: "patch" }] };
  assert.equal(await analyze(withDepsRule, [commit("a", "chore(deps): bump foo")]), "patch");
});

test("default export shape: branches and plugin list", () => {
  assert.equal(config.branches, branches);

  const names = config.plugins.map(pluginName);
  assert.deepEqual(names, [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/changelog",
    "@semantic-release/npm",
    "@semantic-release/git",
    "@semantic-release/github",
    "@kilianpaquier/semantic-release-backmerge",
  ]);

  // A consumer installs this package and semantic-release and nothing
  // else, so every plugin any export hands out must be a dependency here,
  // and every one is an absolute path into this package's own tree, so
  // whichever config names it, this copy is the one that loads.
  for (const entry of [...config.plugins, changelog, npm, git(), github(), backmerge, exec]) {
    const path = Array.isArray(entry) ? entry[0] : entry;
    const name = pluginName(entry);
    assert.ok(name in pkg.dependencies, `"${name}" is used by the config but missing from package.json dependencies`);
    assert.ok(path.startsWith("/"), `"${name}" is handed out as a bare name, which semantic-release resolves from its own directory`);
    assert.ok(existsSync(path), `"${name}" resolves to a file that does not exist: ${path}`);
    assert.notEqual(name, path, "pluginName maps a path back to its package name");
  }
});

test("commitAnalyzer() overrides replace shared rules, so a shared rule can be switched off", async () => {
  // The analyzer treats a `release: false` match as undecided and lets a
  // later matching rule win, so an override that merely sat beside the
  // shared rule could never turn it off.
  const [, pluginConfig] = commitAnalyzer({ releaseRules: [{ type: "refactor", release: false }] });
  const refactorRules = pluginConfig.releaseRules.filter((r) => r.type === "refactor");
  assert.deepEqual(refactorRules, [{ type: "refactor", release: false }]);
  assert.equal(await analyzeCommits(pluginConfig, { ...baseContext, commits: [commit("a", "refactor: reshape thing")] }), null);
  // Rules with no shared twin are added, and the shared ones still apply.
  assert.equal(pluginConfig.releaseRules.length, releaseRules.length);
});

test("git() and github() take overrides, so a composed config never needs plugin() for them", () => {
  // A repo whose tagFormat prefixes the version wants the release commit to
  // match; a repo without release labels wants the GitHub plugin muted.
  // Without these overrides both had to rebuild the entries by hand.
  const message = "chore(release): v${nextRelease.version} [skip ci]\n\n${nextRelease.notes}";
  const [, gitDefaults] = git();
  const [, gitOverridden] = git({ assets: ["Cargo.toml"], message });
  assert.equal(gitDefaults.message, commitMessage);
  assert.deepEqual(gitOverridden, { assets: ["Cargo.toml"], message });

  const [, githubDefaults] = github();
  const [, githubMuted] = github({ successComment: false, releasedLabels: false, assets: [] });
  assert.deepEqual(githubDefaults, { releasedLabels: ["release:<%= nextRelease.channel ? 'staging' : 'prod' %>"] });
  assert.deepEqual(githubMuted, { releasedLabels: false, successComment: false, assets: [] });
  assert.equal(pluginName(github({ failComment: false })), "@semantic-release/github");
});

test("version discipline: the beta plugins stay pinned exact", () => {
  // Renovate offers the matching stable release from an exact prerelease
  // pin; a caret range would make that bump invisible and silently swap
  // back in the release-notes-generator 14 regression this package exists
  // to avoid. Remove this test once both plugins are on a stable release.
  const exactRange = /^\d+\.\d+\.\d+-/;
  assert.match(
    pkg.dependencies["@semantic-release/release-notes-generator"],
    exactRange,
    "release-notes-generator must stay pinned to an exact beta version",
  );
  assert.match(
    pkg.dependencies["@semantic-release/commit-analyzer"],
    exactRange,
    "commit-analyzer must stay pinned to an exact beta version",
  );
  assert.match(pkg.dependencies["conventional-changelog-conventionalcommits"], /^\^10\./);
});
