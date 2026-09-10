// This repo's own release, composed from the shared config it ships. Same
// package, same import, a consuming repo would write to extend its own plugin
// list. Dogfooding it this way means a break in the shared config breaks this
// repo's own release first. Here the package resolves through the npm
// workspace; a consumer gets it linked in by actions/semantic-release-config.

import { commitAnalyzer, releaseNotes, changelog, git, github, exec } from "@dodi-smart/semantic-release-config";

export default {
  branches: ["main"],
  plugins: [
    commitAnalyzer({
      releaseRules: [
        // Renovate labels every bump here `chore(deps)`, and the shared preset
        // deliberately makes that inert everywhere else. Here the dependencies
        // are the action versions these workflows run on, so a bump that never
        // released would leave every caller pinned to v1 on the old ones.
        { type: "chore", scope: "deps", release: "patch" },
        // The shared rules release a patch on `refactor:`. This repo never did,
        // and a release that moves `v1` under every caller for a change with
        // no visible entry is not one to introduce by accident.
        { type: "refactor", release: false },
      ],
    }),

    // Each entry here replaces the shared entry of the same type in place, so
    // section order stays the shared one. This repo hides
    // docs/style/refactor/test/build/ci from its notes; the shared default
    // shows them.
    releaseNotes({
      types: [
        { type: "chore", scope: "deps", section: "⬆️ Dependencies", effect: "bump" },
        { type: "docs", effect: "hidden" },
        { type: "style", effect: "hidden" },
        { type: "refactor", effect: "hidden" },
        { type: "test", effect: "hidden" },
        { type: "build", effect: "hidden" },
        { type: "ci", effect: "hidden" },
      ],
    }),

    changelog,

    // The shared package is never published, so nothing writes a version into
    // semantic-release/package.json and there is nothing of it to commit.
    git({ assets: ["CHANGELOG.md"] }),

    // No release:prod / release:staging labels exist here, and a label that
    // does not exist fails the release.
    github({ releasedLabels: false }),

    [exec, { successCmd: "git tag -f v${nextRelease.version.split('.')[0]} ${nextRelease.gitTag} && git push -f origin v${nextRelease.version.split('.')[0]}" }],
  ],
};
