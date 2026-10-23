// A wrapped plugin that has only verifyConditions, to prove a lifecycle it
// lacks is a no-op and not a crash.
export const verifyConditions = () => "verified";
