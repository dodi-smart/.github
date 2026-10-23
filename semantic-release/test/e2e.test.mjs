// Real semantic-release dry runs over consumer configs, against a local bare
// repository, with no network, through the shipped installer.
//
// The unit tests import the plugins directly, which proves the shared config
// is right but not that semantic-release loads the plugins the package pins.
// By default it does not: a plugin named in a config resolves from
// semantic-release's own directory, so the stable copies it ships with win.
// The package therefore hands out plugins as absolute paths. These runs hold
// that line in the two shapes the reusable release workflow offers, both of
// which once broke: a composed config with no `extends` at all, and a module
// config loaded with `--extends <file>`, which replaces the config's own
// `extends`. Both name a plugin the default config does not list.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", "..");
const require = createRequire(import.meta.url);
const bin = require.resolve("semantic-release/bin/semantic-release.js");

// No global or system git config: a machine with commit signing on would
// otherwise hang the commits below on a passphrase prompt.
const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", CI: "", GITHUB_ACTIONS: "" };
const git = (cwd, ...args) => execFileSync("git", args, { cwd, env: gitEnv, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });

const work = mkdtempSync(join(tmpdir(), "semantic-release-config-e2e-"));
const prefix = join(work, "prefix");
after(() => rmSync(work, { recursive: true, force: true }));

// One install for both runs; the installer's own test covers it in isolation.
before(() => {
  mkdirSync(prefix);
  execFileSync(join(root, "actions", "semantic-release-config", "install.sh"), [root, join(work, "seed")], {
    env: { ...process.env, SEMANTIC_RELEASE_CONFIG_PREFIX: prefix },
    stdio: ["ignore", "pipe", "pipe"],
  });
});

// A consumer repo: a clone of a bare remote, on main, holding one commit of
// each kind the assertions look for, with the package linked in by name the
// way the installer leaves it.
function consumer(name, files) {
  const remote = join(work, name + ".git");
  const repo = join(work, name);
  git(work, "init", "--quiet", "--bare", "--initial-branch=main", remote);
  git(work, "clone", "--quiet", "file://" + remote, repo);
  git(repo, "config", "user.email", "test@example.com");
  git(repo, "config", "user.name", "test");
  git(repo, "checkout", "--quiet", "-b", "main");
  execFileSync(join(root, "actions", "semantic-release-config", "install.sh"), [root, repo], {
    env: { ...process.env, SEMANTIC_RELEASE_CONFIG_PREFIX: prefix },
    stdio: ["ignore", "pipe", "pipe"],
  });
  writeFileSync(join(repo, ".gitignore"), "node_modules\n");
  writeFileSync(join(repo, "package.json"), JSON.stringify({ name: "consumer", version: "0.0.0", private: true }) + "\n");
  for (const [file, content] of Object.entries(files)) writeFileSync(join(repo, file), content);
  git(repo, "add", "-A");
  git(repo, "commit", "--quiet", "-m", "feat: first thing");
  git(repo, "commit", "--quiet", "--allow-empty", "-m", "docs: readme");
  git(repo, "commit", "--quiet", "--allow-empty", "-m", "chore: tidy");
  git(repo, "push", "--quiet", "origin", "main");
  return repo;
}

function dryRun(repo, ...args) {
  const output = execFileSync(process.execPath, [bin, "--dry-run", "--no-ci", ...args], {
    cwd: repo,
    env: gitEnv,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return output.slice(output.indexOf("Release note for version"));
}

function assertNotes(notes) {
  assert.match(notes, /### ✨ Features/, "no Features section: the stable generator loaded instead of the pinned one, or notes came out empty");
  assert.match(notes, /first thing/);
  assert.match(notes, /### 📚 Documentation/, "docs: is shown by the shared config");
  assert.doesNotMatch(notes, /tidy/, "chore: is hidden by the shared config and must not leak");
}

// exec is not in the default config, so nothing but the path the package
// hands out could make it load. verifyConditionsCmd proves it ran.
const composed = `
import { commitAnalyzer, releaseNotes, exec } from "@dodi-smart/semantic-release-config";
export default {
  branches: ["main"],
  plugins: [commitAnalyzer(), releaseNotes(), [exec, { verifyConditionsCmd: "echo exec-ran" }]],
};
`;

test("e2e: a composed config with no extends loads the pinned plugins", () => {
  const repo = consumer("composed", { "release.config.mjs": composed });
  assertNotes(dryRun(repo));
});

test("e2e: a module config loaded with --extends <file> loads the pinned plugins", () => {
  const repo = consumer("modules", { ".releaserc.core.mjs": composed });
  assertNotes(dryRun(repo, "--extends", "./.releaserc.core.mjs"));
});

// The default plugin set's changelog, npm and git(), in a real (not dry) run on
// a local remote: a stable release commits the changelog and the version, a
// prerelease tags and commits nothing. This is the property that keeps the
// integration branch from rewriting the version lines a release rewrites.
const release = `
import { branches, commitAnalyzer, releaseNotes, changelog, npm, git } from "@dodi-smart/semantic-release-config";
export default {
  branches,
  plugins: [commitAnalyzer(), releaseNotes(), changelog, npm, git()],
};
`;

// Both streams: semantic-release logs to stderr.
function run(repo, ...args) {
  const r = spawnSync(process.execPath, [bin, "--no-ci", ...args], { cwd: repo, env: gitEnv, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  return r.stdout + r.stderr;
}

test("e2e: a stable release commits the release, a prerelease on develop commits nothing", () => {
  const repo = consumer("stable-only", { "release.config.mjs": release });

  // develop: a prerelease. It tags, and the tip stays the commit it was.
  git(repo, "checkout", "--quiet", "-b", "develop");
  git(repo, "push", "--quiet", "origin", "develop");
  const before = git(repo, "rev-parse", "HEAD").trim();
  const out = run(repo);
  assert.match(out, /Skip prepare: branch "develop" is a prerelease branch/);
  assert.match(git(repo, "tag", "--list").trim(), /^v1\.0\.0-develop\.1$/m);
  assert.equal(git(repo, "rev-parse", "HEAD").trim(), before, "a prerelease committed");
  // npm's publish step bumps package.json in the working tree itself when its
  // prepare did not run. It is never committed, and the job that ran it ends.
  assert.equal(git(repo, "status", "--porcelain", "--untracked-files=no").trim(), "M package.json", "a prerelease changed more than the working tree's package.json");
  assert.equal(JSON.parse(git(repo, "show", "HEAD:package.json")).version, "0.0.0", "a prerelease committed a version");
  git(repo, "checkout", "--quiet", "--", "package.json");

  // main: a stable release commits the changelog and the version.
  git(repo, "checkout", "--quiet", "main");
  run(repo);
  const subject = git(repo, "log", "-1", "--format=%s").trim();
  assert.match(subject, /^chore\(release\): 1\.0\.0 \[skip ci\]$/);
  assert.match(git(repo, "show", "--stat", "--format=", "HEAD"), /CHANGELOG\.md/);
  assert.equal(JSON.parse(git(repo, "show", "HEAD:package.json")).version, "1.0.0");
});
