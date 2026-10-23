// The stable-only wrapper: `prepare` runs on a stable release and is skipped
// on a prerelease, so a prerelease commits nothing and the integration branch
// never rewrites the version lines a release rewrites.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import * as stableOnly from "../stable-only.js";
import * as stableOnlyPublish from "../stable-only-publish.js";

const here = dirname(fileURLToPath(import.meta.url));
const fake = resolve(here, "fixtures", "fake-plugin.mjs");
const minimal = resolve(here, "fixtures", "fake-plugin-minimal.mjs");

const calls = (globalThis.__fakePluginCalls ??= []);
beforeEach(() => {
  calls.length = 0;
});

const logger = () => {
  const lines = [];
  return { lines, log: (line) => lines.push(line) };
};

const stable = { branch: { name: "main", type: "release", prerelease: false }, nextRelease: { version: "1.0.0" } };
const prerelease = { branch: { name: "develop", type: "prerelease", prerelease: "develop", channel: "develop" }, nextRelease: { version: "1.0.0-develop.1", channel: "develop" } };

test("prepare runs on a stable release, with the wrapped plugin's own options and no `plugin` key", async () => {
  const context = { ...stable, logger: logger() };
  const result = await stableOnly.prepare({ plugin: fake, changelogFile: "CHANGELOG.md" }, context);
  assert.equal(result, "prepare-result");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].pluginConfig, { changelogFile: "CHANGELOG.md" });
  assert.equal(calls[0].context, context);
  assert.deepEqual(context.logger.lines, []);
});

test("prepare is skipped on a prerelease branch, with one log line", async () => {
  const context = { ...prerelease, logger: logger() };
  const result = await stableOnly.prepare({ plugin: fake }, context);
  assert.equal(result, undefined);
  assert.equal(calls.length, 0);
  assert.equal(context.logger.lines.length, 1);
  assert.match(context.logger.lines[0], /Skip prepare/);
  assert.match(context.logger.lines[0], /branch "develop" is a prerelease branch/);
});

test("prepare is skipped when the release is on a channel, even without a prerelease branch", async () => {
  const context = { branch: { name: "next", type: "release", prerelease: false }, nextRelease: { version: "2.0.0", channel: "next" }, logger: logger() };
  await stableOnly.prepare({ plugin: fake }, context);
  assert.equal(calls.length, 0);
  assert.match(context.logger.lines[0], /channel "next"/);
});

test("prepare runs on a maintenance branch: it has a channel, but its releases are stable", async () => {
  const context = { branch: { name: "1.x", type: "maintenance", prerelease: false }, nextRelease: { version: "1.4.1", channel: "1.x" }, logger: logger() };
  await stableOnly.prepare({ plugin: fake }, context);
  assert.equal(calls.length, 1);
});

test("verifyConditions always runs, on a stable release and on a prerelease", async () => {
  await stableOnly.verifyConditions({ plugin: fake, a: 1 }, { ...stable, logger: logger() });
  await stableOnly.verifyConditions({ plugin: fake, a: 1 }, { ...prerelease, logger: logger() });
  assert.deepEqual(calls.map((c) => c.step), ["verifyConditions", "verifyConditions"]);
  assert.deepEqual(calls[0].pluginConfig, { a: 1 });
});

test("the publishing entry passes publish and addChannel through unchanged, on a prerelease too", async () => {
  const context = { ...prerelease, logger: logger() };
  assert.equal(await stableOnlyPublish.publish({ plugin: fake, npmPublish: false }, context), "publish-result");
  assert.equal(await stableOnlyPublish.addChannel({ plugin: fake, npmPublish: false }, context), "addChannel-result");
  assert.deepEqual(calls.map((c) => c.step), ["publish", "addChannel"]);
  assert.deepEqual(calls[0].pluginConfig, { npmPublish: false });
  assert.equal(calls[0].context, context);
  // ...and still gates prepare.
  await stableOnlyPublish.prepare({ plugin: fake }, context);
  assert.equal(calls.length, 2);
});

test("an entry only exports the lifecycles semantic-release should call on it", () => {
  // semantic-release decides which steps a plugin takes part in from its
  // exports, and a publish step on a plugin that publishes nothing adds an
  // empty release to what the success step reads.
  const steps = (mod) => Object.keys(mod).filter((k) => ["verifyConditions", "prepare", "publish", "addChannel", "success", "fail"].includes(k)).sort();
  assert.deepEqual(steps(stableOnly), ["prepare", "verifyConditions"]);
  assert.deepEqual(steps(stableOnlyPublish), ["addChannel", "prepare", "publish", "verifyConditions"]);
  assert.notEqual(stableOnly.prepare, stableOnlyPublish.prepare, "entries must not share function objects: semantic-release stamps a pluginName on each");
});

test("a lifecycle the wrapped plugin lacks is a no-op", async () => {
  const context = { ...stable, logger: logger() };
  assert.equal(await stableOnly.verifyConditions({ plugin: minimal }, context), "verified");
  assert.equal(await stableOnly.prepare({ plugin: minimal }, context), undefined);
});

test("the wrapped plugin must be an absolute path", async () => {
  const context = { ...stable, logger: logger() };
  await assert.rejects(stableOnly.prepare({ plugin: "@semantic-release/changelog" }, context), /absolute path/);
  await assert.rejects(stableOnly.verifyConditions({}, context), /absolute path/);
});
