// `stable-only.js` plus the lifecycles a publishing plugin carries, for
// `npm`: `publish` and `addChannel` run on every branch, unchanged. Kept as a
// second entry because semantic-release decides which steps a plugin takes
// part in from the functions its module exports, and an entry that exported
// `publish` for a plugin without one would add an empty release to the list
// the success step reads.
//
// `npm` on a prerelease: `prepare` is skipped, so `publish` runs the version
// bump itself (the plugin does when `prepare` has not), in the working tree and
// uncommitted. With `npmPublish: false`, as `npm` in `index.js` sets, nothing
// else follows. A config that publishes would publish the right version, but
// from a tree the commit never carried.

import { lifecycles } from "./stable-only.js";

export const { verifyConditions, prepare, publish, addChannel } = lifecycles(["publish", "addChannel"]);
