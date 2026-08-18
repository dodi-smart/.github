# Agent instructions

This repo holds the org's reusable workflows, the composite actions they are
built from, the org-inherited issue templates, and the shared Renovate preset.
`README.md` explains what each does and how to call it; this file is the part you
must read **before changing anything**.

## Read this first

The reasoning behind these files is recorded elsewhere, privately, as decision
records with ids like `DODI-00008`. Those records cannot inject themselves into
this repo, so the table below restates each one next to the file it governs. The
ids are citations, not links — treat the prose here as the authority.

Several of those records carry executable checks that **fetch these files over
the API** and assert on their contents. So a change here can fail a check in
another repo. That is intentional: a decision about a file in another repo should
be verified rather than asserted.

## What governs what

| File | Rule | Why it exists |
|---|---|---|
| `actions/agent-gate/` | **DODI-00008** — `agent:no-touch` is evaluated FIRST, with no exemption | Position matters as much as existence. A check placed after an early return silently stops covering that path. This action exists so the rule has one implementation instead of one per workflow. `test.sh` asserts it across every workflow shape; do not weaken those cases. |
| all agent workflows | **DODI-00005** — deterministic gates run before any agent step, and the runner picker carries the same `if:` as the job it feeds | An agent explaining a compile error is pure waste, and the picker itself costs a hosted minute, so neither may run for an event that will not proceed. |
| `.github/workflows/pr-review.yml` | **DODI-00005** — no `synchronize` trigger | Reviewing every push is what got the previous review workflow muted, and a muted bot reviews nothing. |
| `.github/workflows/deps-verify.yml` | **DODI-00004** — verification never confers merge authority | It must never merge, approve, or change mergeability. Evidence is only useful if it is allowed to be wrong; merging on a clean verdict forces conservative tuning, which produces noise, which gets the report ignored. |
| `.github/workflows/issue-implement.yml` | **DODI-00019** — a plan is required, `Agent mode` gates who may ask, and the PR is always a draft | The check is a field comparison in a gate job, not a question put to the agent, and it has no override. An agent asked whether a plan is adequate will sometimes accept a two-line issue body. |
| `.github/workflows/issue-implement.yml` | **DODI-00003** — `Triage state` stops at "Ready for agent" | Do not add an "in progress" state. The open draft PR and the closed issue already say it, and a mirror is correct only while someone maintains it. |
| `.github/workflows/claude-assist.yml` | **DODI-00014** — `@claude` mentions are a governed workflow, not a per-repo file | This was the one agent workflow the standard did not own, and the only one that did not check `agent:no-touch` — a hole in the kill switch, in the widest surface in the org. Its reserved-verb list must stay the single place those verbs are named. |
| `.github/workflows/pick-runner.yml` | **DODI-00010** — runners are selected by generic capability; public repos and fork PRs always use hosted | Never select by a hardware nickname or a machine name — those are re-registration-unstable and tie every caller to today's fleet. Public repos and fork PRs have no opt-out: a fork PR would run attacker-authored code on our hardware against a cache that persists into the next job. |
| `.github/workflows/pick-runner.yml` | **DODI-00012** — the picker validates its own selector | Falling back to hosted on error is correct, but it makes a selector matching nothing look exactly like a busy fleet. The validation is why that bug cannot hide again. It **warns rather than fails**: a bad selector still runs correctly on hosted, and failing CI over a cost regression would be worse than the bug. |
| `actions/setup-stack/` | **DODI-00015** — stack is an input; there is no template per stack | Never add a per-stack caller template, and never put a product-specific task, module or scheme name in this repo. The previous Gradle template carried one product's task name into every repo told to copy it. |
| all workflows | **DODI-00017** — callers pin a released tag | `v1` moves only after a change runs green on a real repo. Changing or removing an input is breaking: add an alias and warn (as `deps-verify` does for `setup:`), or cut `v2`. |
| `README.md` | **DODI-00018** — this repo is public and self-contained | Never link to the private standards repo. Restate the reasoning instead: a link into a private repo is a 404 to everyone who follows it, which is worse than no link because it reads as an offer. |

## Facts worth not rediscovering

- **`--allowed-tools <tools...>` is VARIADIC** — space-separated, each entry
  quoted if it contains parentheses. A comma-joined list parses as one meaningless
  token: nothing matches, every `Bash` call is denied with "This command requires
  approval", and the job still reports **SUCCESS**. Use `actions/run-agent`, which
  gets this right.
- **`display_report` defaults to false**, which makes a run that did nothing
  indistinguishable from one that worked. `run-agent` forces it on.
- **`allowed_bots` is load-bearing for `deps-verify`.** Without it the action
  aborts with "Workflow initiated by non-human actor". Every run there is
  bot-initiated, so the default makes the workflow impossible.
- **The `secrets` context is not available in a step-level `if:`.** Hoist the
  presence check into an env var — `pick-runner` does this.
- **Composite action steps support `if:`**, and reference other actions by
  `owner/repo/path@ref` — no checkout needed.
- **`actions/create-github-app-token` takes `client-id`;** `app-id` is deprecated
  upstream. actionlint ships a stale snapshot of that action's inputs and will
  report both as errors. `Self test` ignores exactly those two messages.
- **BSD/macOS `mktemp -d` with no template ignores `TMPDIR`.** This org has macOS
  runners, so always pass an explicit template.
- **Broad `Bash` in the agent allowlist is deliberate.** The bound is not the
  allowlist — the action refuses to run for an actor without write access, so
  untrusted content only reaches the agent when someone trusted invokes it.

## Known follow-up: the internal self-references still say `@main`

The workflows here call each other — and their composite actions — at `@main`,
while callers outside are told to pin `@v1`. That is inconsistent, and it means a
`@v1`-pinned caller still picks up `main`'s `pick-runner` and actions. It
undercuts what pinning is for, so it is a gap to close, not a design.

It is deliberate only in its ORDER. Repos that have not migrated still pin
`@main`, so flipping the internal references to `@v1` before they move would
break them in the window between merge and migration. The sequence is:

1. Merge with internal references at `@main` — existing `@main` callers keep working.
2. Cut `v1`.
3. Migrate every repo to `@v1`.
4. **Then** flip the internal references to `@v1` and move the tag.

Step 4 is the one that gets forgotten. Until it is done, `@v1` pins the workflow
bodies but not what they call.

## If you add a workflow

1. Gate it with `actions/agent-gate` so `agent:no-touch` is checked first.
2. Run it through `actions/run-agent` rather than calling the action directly.
3. Add its governing decision ids to the table above, **with the reasoning
   written out** — a workflow nobody recorded a reason for is one the next person
   will "simplify".
4. If it introduces a new gate shape, add cases to `actions/agent-gate/test.sh`.
5. If it adds a `@claude` verb, add that verb to `claude-assist.yml`'s
   `reserved-commands` default in the same change, or the assistant answers it too.
