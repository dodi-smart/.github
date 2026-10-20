// The org's commitlint rules: config-conventional, with the line limits raised.
//
// Agent-written commits carry long "Why:" lines and session URLs, and the whole
// pull request history is linted, so one long body line used to fail every later
// push. Several repos hand-patched their own config to 180 in slightly different
// shapes. This is the one copy. A repo extends it by name and adds only what is
// its own.
//
// A body or footer line over 180 is a warning: it is worth a look but never
// worth blocking a merge. The header stays an error, because it is the line
// every log, release note and changelog shows. subject-case is left as
// config-conventional has it (an error).
//
// This package declares no dependency: config-conventional resolves from the
// node_modules of the one install, so it stays pinned in ../package.json.
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'header-max-length': [2, 'always', 180],
    'body-max-line-length': [1, 'always', 180],
    'footer-max-line-length': [1, 'always', 180],
  },
};
