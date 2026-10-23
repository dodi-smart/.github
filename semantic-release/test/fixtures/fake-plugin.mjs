// A stand-in for a wrapped plugin: records each lifecycle call and what it
// was handed, on globalThis so the test can read it without importing this
// module a second time under a different URL.
const calls = (globalThis.__fakePluginCalls ??= []);

const record = (step) => (pluginConfig, context) => {
  calls.push({ step, pluginConfig, context });
  return `${step}-result`;
};

export const verifyConditions = record("verifyConditions");
export const prepare = record("prepare");
export const publish = record("publish");
export const addChannel = record("addChannel");
