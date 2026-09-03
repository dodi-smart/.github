# Agent instructions

This repo holds the org's reusable workflows, the composite actions they are
built from, the org-inherited issue templates, and the shared Renovate preset.
`README.md` explains what each does and how to call it; this file is the part you
must read **before changing anything**.

## This repo is public

It is public because a workflow run has to be able to read it, and that is
simpler than handing every repo a token for a private one. Everything in it is
visible to anyone, and so is everything about it. File contents, comments,
commit messages, pull request titles and bodies, issue text.

The org's own repositories are private. Keep them that way.

- **Never name a product, repository, customer, host or internal URL here.** Not
  in code, not in a comment, not in a commit message, not in a pull request
  description. Write "a Gradle repo" or "a consuming repo" instead.
- **Never carry a product-specific value in a shared file.** A Gradle task name,
  a module name, an Xcode scheme. Those belong to the caller.
- **Never link to a private repo.** A link that 404s for everyone who follows it
  is worse than no link, because it reads as an offer.

Everything here also has to stand on its own. A reader with nothing but this
repo should be able to change it safely, so write the reason next to the rule
and keep it to a line or two. A pointer to somewhere they cannot reach is not a
reason.

## What governs what

Each row is a rule you should not break without deciding to. The third column is
why, not history.

| File | Rule | Why |
|---|---|---|
| `actions/agent-gate/` | `agent:no-touch` is evaluated FIRST, with no exemption | Position matters as much as existence. A check after an early return stops covering that path. `test.sh` asserts it across every workflow shape. Do not weaken those cases. |
| all agent workflows | Deterministic gates run before any agent step, and the runner picker carries the same `if:` as the job it feeds | An agent explaining a compile error is waste, and the picker is itself a hosted job. Neither may run for an event that will not proceed. |
| `.github/workflows/pr-review.yml` | No `synchronize` trigger | Reviewing every push is what gets a review bot muted, and a muted bot reviews nothing. |
| `.github/workflows/deps-verify.yml` | Verification never merges, approves, or changes mergeability | Evidence is only useful if it is allowed to be wrong. Merging on a clean verdict forces conservative tuning, which produces noise, which gets the report ignored. |
| `.github/workflows/issue-implement.yml` | A plan is required, `Agent mode` gates who may ask, and the PR is always a draft | The check is a field comparison in a gate job, never a question put to the agent, and it has no override. An agent asked whether a plan is adequate will sometimes accept a two-line issue body. |
| `.github/workflows/issue-triage.yml` | Issue-field ids resolve repo-scoped, and triage fails if it did not record `Triage state` | This job runs on a repo-scoped App installation with no org permission, so the org issue-fields endpoint returns 403 and always will. Resolve ids from `repository(owner,name){ issueFields }`. Never offer the org path as a fallback. Keep the final verification step, or the job reports success with the fields unwritten. |
| `.github/workflows/issue-implement.yml` | `Triage state` stops at "Ready for agent" | Do not add an "in progress" state. The open draft PR and the closed issue already say it, and a mirror is correct only while someone maintains it. |
| `.github/workflows/claude-assist.yml` | `@claude` mentions are a governed workflow, not a per-repo file | It is the widest agent surface in the org, so it needs the same kill switch as the rest. Its reserved-verb list stays the single place those verbs are named. |
| `.github/workflows/react-doctor.yml` | The caller owns triggers, `concurrency` and `paths:`, and the picker is gated by the caller's own `if:` | Keep `blocking: none`, the action's own default. A threshold tuned before there is a baseline produces noise, and noise is what gets a check ignored. The caller's `paths:` filter is POSITIVE, so a filtered-out pull request produces no check run. Never make it a required status check. |
| `.github/workflows/zavet-check.yml` | A dependency bot's PR is report-only: checks and guards still run and comment, but never fail the job | Renovate and Dependabot can neither write a decision trailer nor repair a decision, so a red check on their PRs blocks automerge without producing anyone who can act. Human PRs still fail closed. |
| `.github/workflows/zavet-check.yml` | A decision check that could not run is reported apart from one that ran and failed, and both fail the job | Fail-closed is about the verdict, not the diagnosis. A missing runner or a missing toolchain exits 127, which as a bare exit code reads as a decision that stopped holding, and sends the reader looking for a broken decision that does not exist. The one case that passes is a knowledge layer declaring no `checks:` at all, because then nothing was meant to run. |
| `.github/workflows/pick-runner.yml` | Runners are selected by capability label, never by architecture or machine name; public repos and fork PRs always use hosted | An architecture pins a tier of intent to this month's hardware, and a machine name does not survive re-registration. The public and fork guard has no opt-out: a fork PR would run attacker-authored code on our hardware against a cache the next job inherits. |
| `.github/workflows/pick-runner.yml` | The picker validates its own selector | Falling back is correct, and it makes a selector matching nothing look exactly like a busy fleet. It warns rather than fails, because a bad selector still runs on the fallback and breaking CI over it would be worse than the bug. |
| `.github/workflows/pick-runner.yml` | `light` and `heavy` are tiers of intent | Ask for the one that describes the work. Re-tier by editing the `case` block and the README table together; `Self test` fails if they disagree. |
| `actions/setup-stack/` | Stack is an input; there is no template per stack | Five stacks across three workflows is fifteen files to keep in agreement. Never add a per-stack caller template, and never put a product-specific task, module or scheme name in this repo. |
| `actions/setup-stack/` | Package caches persist per runner; GitHub cache is hosted-only and never uses restore-keys | Isolation must name every package manager the image persists, because pnpm and yarn read their own env vars. `PUB_CACHE` is job-scoped in every mode, since no volume backs it. Hosted cache is one mechanism per stack, never a package store, and never `restore-keys` on one: that is how a poisoned entry reimports. |
| `.github/workflows/pr-checks.yml` | PR checks use local home on self-hosted, `cache: auto` | All three `setup-stack` calls pass `isolate: false` and `cache: auto`. Auto becomes true only on `github-hosted`. |
| `.github/workflows/deps-verify.yml` | Verification isolates and never uses GitHub package cache | Hard-coded `isolate: true` and `cache: false`. Not a caller-facing input: a verification job that can see yesterday's tree is not verifying. |
| `.github/workflows/release.yml` | `released`/`version`/`tag`/`tags` outputs come from a tag diff around the `Release` step, never from parsing semantic-release's own output | Tag-diff is stack-agnostic: it works for `modules`, for a custom `release-command`, and needs no cooperation from the caller's `.releaserc`. Adding an output is additive; do not remove or repurpose one without cutting `v2`. |
| all workflows | Callers pin a released tag | `v1` moves only after a change runs green on a real repo. Changing or removing an input is breaking. Add an alias and warn, as `deps-verify` does for `setup:`, or cut `v2`. |
| `README.md` | The onboarding badge says `v1`, and it moves only when the tag it names does | The badge in a consuming repo's README asserts that repo calls these workflows at `@v1`. It is verified against live state by the onboarding tooling, which fails a repo displaying it while its workflows are disabled or its properties unset. Changing the badge's version here without cutting that version is how every onboarded repo starts advertising something untrue at once. |
| `README.md` | The badge names no repo but this one | It is rendered inside repos this org does not control the visibility of, and it is the one artefact from here that a reader outside the org may see in context. Keep its text to what these workflows are, never who uses them. |

## Facts worth not rediscovering

- **`--allowed-tools <tools...>` is VARIADIC.** Space-separated, each entry
  quoted if it contains parentheses. A comma-joined list parses as one meaningless
  token: nothing matches, every `Bash` call is denied with "This command requires
  approval", and the job still reports **SUCCESS**. Use `actions/run-agent`, which
  gets this right.
- **`display_report` defaults to false**, which makes a run that did nothing
  indistinguishable from one that worked. `run-agent` forces it on.
- **Tag mode cannot run a slash command, and hands the agent write access.**
  Tag mode does not let you choose the prompt: it generates its own and appends
  yours inside `<custom_instructions>` at the end (`create-prompt/index.ts:478`).
  The whole file is one user message, and a slash command only expands at the
  START of a message, so `/code-review:code-review` several hundred lines in is
  plain text and the plugin never runs. `override_prompt` looks like the way out
  and is not. It is declared in `collect-inputs.ts` and read nowhere. Tag mode
  also calls `setupBranch` and configures git for pushing, which `deps-verify`
  must never have. That is why `actions/sticky-comment` exists
  instead of `use_sticky_comment`.
- **A non-empty `prompt` puts the action in AGENT mode, which posts nothing.**
  `use_sticky_comment` is read only in tag mode, so setting it beside a prompt is
  a no-op and the report reaches the job summary alone. `run-agent` fails that
  combination and `Self test` catches it at review time. An agent publishes only
  what you tell it to publish, so tell it, then **assert that it did**: both
  workflows fail if the pull request records nothing from the run.
- **`track_progress` forces TAG mode, and tag mode knows three issue actions.**
  `opened`, `assigned`, `labeled`. Anything else, `reopened` included, throws
  `Unsupported issue action` in Create prompt and fails the job before the agent
  starts. `actions/run-agent` drops the progress comment for those events and
  runs in agent mode instead, so a reopened issue is triaged rather than
  reported red. Narrow that list if upstream narrows; never widen it.
- **Agent mode starts the inline-comment MCP server only when its tool is named
  in the allowlist.** `mcp__github_inline_comment__create_inline_comment` must be
  in `allowed-tools`, or the server never starts and the tool does not exist.
- **The `code-review` plugin posts only with `--comment`,** and parses nothing
  else off the command line. Its own instructions end step 7 with "if `--comment`
  was NOT provided, stop here". The review depth this repo computes travels in
  the system prompt, because an extra word on the slash command is discarded.
- **A label already present emits no `labeled` event.** So a request label must
  be cleared when the job finishes, or asking again does nothing. `pr-review`
  clears `agent:review` and `issue-triage` clears `agent:triage`.
- **`allowed_bots` is load-bearing for `deps-verify`.** Without it the action
  aborts with "Workflow initiated by non-human actor". Every run there is
  bot-initiated, so the default makes the workflow impossible.
- **The `secrets` context is not available in a step-level `if:`.** Hoist the
  presence check into an env var. `pick-runner` does this.
- **Composite action steps support `if:`**, and reference other actions by
  `owner/repo/path@ref`, with no checkout needed.
- **`actions/create-github-app-token` takes `client-id`;** `app-id` is deprecated
  upstream. actionlint ships a stale snapshot of that action's inputs and will
  report both as errors. `Self test` ignores exactly those two messages.
- **BSD/macOS `mktemp -d` with no template ignores `TMPDIR`.** This org has macOS
  runners, so always pass an explicit template.
- **Broad `Bash` in the agent allowlist is deliberate.** The bound is not the
  allowlist. The action refuses to run for an actor without write access, so
  untrusted content only reaches the agent when someone trusted invokes it.

## Everything here is pinned, including the internal references

The workflows in this repo call each other, and their composite actions, at
`@v1`, the same ref callers outside are told to pin. Otherwise a
`@v1` pin holds the workflow bodies but not the picker and actions they call.

`v1` is moved by semantic-release, not by hand. `.releaserc.json` runs a
`successCmd` that force-moves the major tag onto each release, so the version
comes from the commit messages and the tag follows it. Write conventional commits
or nothing is released.

Three consequences, and the first one is the one people get wrong:

- **Merging to `main` is a rollout, not a staging step.** The tag moves in the
  same run, so every caller is on the new code before anyone looks at it. That
  includes the picker and composite actions these workflows call at `@v1`
  internally. Verify in the pull request. After the merge it is already live.
- **Rolling back is a tag move.** `git tag -f v1 <previous tag> && git push -f
  origin v1`. There is no other undo, because the callers hold no version of
  their own.
- **Cutting `v2` means updating these internal references too.** They are part of
  the release, not incidental to it. The `successCmd` needs no change: it derives
  the major from the version, so `2.0.0` creates `v2` and leaves `v1` frozen at
  the last `1.x`. What does need adding is a maintenance branch in
  `.releaserc.json` if a `1.x` patch will ever be released, because `main` is the
  only release branch today.

This repo also releases on `chore(deps)`, which the shared Renovate preset
deliberately makes inert everywhere else. The dependencies here are the action
versions these workflows run on, so a bump that never reached a release would
leave every caller pinned to `@v1` on the old ones. The rule is scoped to the
`deps` scope, so a plain `chore:` still releases nothing, and `Self test` fails
if the rule is removed.

## This repo's own CI is hosted, and has to be

`Self test` and `Publish release` both run on `ubuntu-latest`. That is not a
preference. The org runner group sets `allows_public_repositories: false` and
this repo is public, so a self-hosted job here is never picked up. It queues
until it times out, which reads like a hang rather than a refusal. Do not "fix"
either workflow by pointing it at the light pool.

`Publish release` also does not call the reusable `release.yml`, and cannot. That
workflow uses `actions/setup-stack@v1`, and on a fresh repo no `v1` exists, so
the first release could never run. A relative `./` reference does not help,
because inside a reusable workflow it resolves against the calling repo. That is
also why every consumer-facing workflow must keep the full
`owner/repo/path@ref` form.

## If you add a workflow

1. Gate it with `actions/agent-gate` so `agent:no-touch` is checked first.
2. Run it through `actions/run-agent` rather than calling the action directly.
3. Add its rule to the table above, with the one line that says why. A rule
   nobody wrote a reason for is one the next person will "simplify".
4. If it introduces a new gate shape, add cases to `actions/agent-gate/test.sh`.
5. If it adds a `@claude` verb, add that verb to `claude-assist.yml`'s
   `reserved-commands` default in the same change, or the assistant answers it too.
6. Name it in the README workflow table. `Self test` does not check that table,
   so an undocumented workflow is one nobody adopts.
