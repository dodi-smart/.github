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
| all agent workflows | Deterministic gates run before any agent step. The runner picker runs INSIDE the gate job, as a step after `actions/agent-gate`, conditioned on the gate's own `proceed` | An agent explaining a compile error is waste, and the picker is itself a hosted job. Running it as a step of the gate job, gated on `proceed`, means it can never run for an event that will not proceed, and a run that does proceed pays for one hosted start instead of two. It still never precedes the kill switch: `agent-gate` runs first in the same job, unconditionally. |
| `.github/workflows/pr-review.yml` | No `synchronize` trigger | Reviewing every push is what gets a review bot muted, and a muted bot reviews nothing. |
| `.github/workflows/deps-verify.yml` | Verification never merges or approves. It may push fix commits to the dependency branch: code only, never a lockfile or version catalog, at most two rounds, pushed by a deterministic step and never by the agent | Evidence is only useful if it is allowed to be wrong. Merging on a clean verdict forces conservative tuning, which produces noise, which gets the report ignored. A fix is a plain commit anyone can read or revert, so it is still evidence. The push step checks author and files because the agent is told the rules, not bound by them. |
| `.github/workflows/deps-verify.yml` | The label and the comment are written by the job from the agent's files, never by the agent. A red build that was not fixed is `deps:needs-manual`, and a branch with fix commits is `deps:fixed`, never `deps:verified` | An agent that labels its own verdict left two labels on one PR and none on another. A later automerge rule must be able to tell a clean bump from one a machine edited. |
| `.github/workflows/deps-verify.yml` | Each command runs in its own subshell, and `env`/`build-env` mean exactly what they mean in `pr-checks.yml` | One shell for every step let a caller's `cd app && ...` break every later step, and a build without pr-checks' placeholders failed on a missing variable. Both came out as a red verdict on an update that was fine. |
| `.github/workflows/issue-implement.yml` | A plan is required, `Agent mode` gates who may ask, and the PR is always a draft | The check is a field comparison in a gate job, never a question put to the agent, and it has no override. An agent asked whether a plan is adequate will sometimes accept a two-line issue body. |
| `.github/workflows/issue-triage.yml` | Issue-field ids resolve repo-scoped, and triage fails if it did not record `Triage state` | This job runs on a repo-scoped App installation with no org permission, so the org issue-fields endpoint returns 403 and always will. Resolve ids from `repository(owner,name){ issueFields }`. Never offer the org path as a fallback. Keep the final verification step, or the job reports success with the fields unwritten. |
| `.github/workflows/issue-triage.yml` | `workflow_dispatch` is a no-op without `issue-number`, never a failure | A dispatch cannot render a tag-mode prompt and carries no issue payload of its own. The gate stops before the runner picker when `issue-number` is empty, with a notice, and the job stays green. A caller offering manual dispatch must declare its own dispatch input and forward it into this `workflow_call` input; the two input kinds are separate. |
| `.github/workflows/issue-implement.yml` | `Triage state` stops at "Ready for agent" | Do not add an "in progress" state. The open draft PR and the closed issue already say it, and a mirror is correct only while someone maintains it. |
| `.github/workflows/claude-assist.yml` | `@claude` mentions are a governed workflow, not a per-repo file | It is the widest agent surface in the org, so it needs the same kill switch as the rest. Its reserved-verb list stays the single place those verbs are named. |
| `.github/workflows/react-doctor.yml` | The caller owns triggers, `concurrency` and `paths:`, and the picker is gated by the caller's own `if:` | Keep `blocking: none`, the action's own default. A threshold tuned before there is a baseline produces noise, and noise is what gets a check ignored. The caller's `paths:` filter is POSITIVE, so a filtered-out pull request produces no check run. Never make it a required status check. |
| `.github/workflows/zavet-check.yml` | A dependency bot's PR is report-only: checks and guards still run and comment, but never fail the job | Renovate and Dependabot can neither write a decision trailer nor repair a decision, so a red check on their PRs blocks automerge without producing anyone who can act. Human PRs still fail closed. |
| `.github/workflows/zavet-check.yml` | A decision check that could not run is reported apart from one that ran and failed, and both fail the job | Fail-closed is about the verdict, not the diagnosis. A missing runner or a missing toolchain exits 127, which as a bare exit code reads as a decision that stopped holding, and sends the reader looking for a broken decision that does not exist. The one case that passes is a knowledge layer declaring no `checks:` at all, because then nothing was meant to run. |
| `.github/workflows/supabase-checks.yml` | Every job runs on `ubuntu-latest`, with no runner picker, and a job disabled by its input reports `skipped`, never `failure` | The self-hosted fleet runs jobs inside containers on a shared daemon, so `supabase db start` publishes postgres's ports on the HOST while the CLI polls the CONTAINER's own localhost — `ubuntu-latest` is the only class here where the CLI's own localhost is the one postgres bound. Reporting `skipped` on a disabled job means a caller can require `types` / `deno` / `pgtap` as status checks on every repo that uses this workflow without breaking the ones that leave one off. |
| `.github/workflows/pick-runner.yml` | Runners are selected by capability label, never by architecture or machine name; public repos and fork PRs always use hosted | An architecture pins a tier of intent to this month's hardware, and a machine name does not survive re-registration. The public and fork guard has no opt-out: a fork PR would run attacker-authored code on our hardware against a cache the next job inherits. |
| `.github/workflows/pick-runner.yml` | The picker validates its own selector | Falling back is correct, and it makes a selector matching nothing look exactly like a busy fleet. It warns rather than fails, because a bad selector still runs on the fallback and breaking CI over it would be worse than the bug. |
| `.github/workflows/pick-runner.yml` | `light` and `heavy` are tiers of intent | Ask for the one that describes the work. Re-tier by editing the `case` block and the README table together; `Self test` fails if they disagree. |
| `actions/pick-runner/` | Runners are selected by capability label, never by architecture or machine name; public repos and fork PRs always use hosted | An architecture pins a tier of intent to this month's hardware, and a machine name does not survive re-registration. The public and fork guard has no opt-out: a fork PR would run attacker-authored code on our hardware against a cache the next job inherits. `.github/workflows/pick-runner.yml` is a thin wrapper around this action; the rule lives here now, for either caller. |
| `actions/pick-runner/` | The picker validates its own selector | Falling back is correct, and it makes a selector matching nothing look exactly like a busy fleet. It warns rather than fails, because a bad selector still runs on the fallback and breaking CI over it would be worse than the bug. |
| `actions/pick-runner/` | `light` and `heavy` are tiers of intent | Ask for the one that describes the work. Re-tier by editing the `case` block and the README table together; `Self test` fails if they disagree. |
| `.github/workflows/pick-runner.yml` | Stays a thin wrapper: identical inputs, outputs and behaviour to `actions/pick-runner/`, nothing more | Every existing caller, and every internal `uses:` at `@v1`, references this exact interface. `Self test` asserts the input and output names survive. |
| `actions/setup-stack/` | Stack is an input; there is no template per stack | Five stacks across three workflows is fifteen files to keep in agreement. Never add a per-stack caller template, and never put a product-specific task, module or scheme name in this repo. |
| `actions/setup-stack/` | Package caches persist per runner; GitHub cache is hosted-only and never uses restore-keys | Isolation must name every package manager the image persists, because pnpm and yarn read their own env vars. `PUB_CACHE` is job-scoped in every mode, since no volume backs it. Hosted cache is one mechanism per stack, never a package store, and never `restore-keys` on one: that is how a poisoned entry reimports. |
| `.github/workflows/pr-checks.yml` | PR checks use local home on self-hosted, `cache: auto` | All three `setup-stack` calls pass `isolate: false` and `cache: auto`. Auto becomes true only on `github-hosted`. |
| `.github/workflows/pr-checks.yml` | ONE hosted `pick` job resolves both runners and `docs_only`; never two picker jobs | Two hosted picker jobs bill two hosted minutes before any real work runs. `checks`, `test`, `build` and `all` all read from this one job's outputs. |
| `.github/workflows/pr-checks.yml` | The `pr-checks` job always runs (`if: always()`) and is the only context a branch ruleset should require | It is the one status-check context that exists on every push in both single-job and split mode, and on a docs-only change where `checks`/`test`/`build`/`all` are skipped. `paths-ignore` on a caller creates no context at all, so a ruleset requiring one waits forever; this job exists precisely so callers can drop `paths-ignore`. |
| `.github/workflows/deps-verify.yml` | Verification isolates and never uses GitHub package cache | Hard-coded `isolate: true` and `cache: false`. Not a caller-facing input: a verification job that can see yesterday's tree is not verifying. |
| `default.json` | `gitIgnoredAuthors` names the author of deps-verify's fix commits, and changes together with `FIX_EMAIL` there | Without it the first fix marks the branch edited, Renovate stops rebasing it, and it can never automerge. |
| `.github/workflows/issue-triage.yml` | Bot-authored issues, the Dependency Dashboard included, are never triaged | A dashboard is a standing status page with nothing to plan, so an agent could only file it as Needs info. |
| `.github/workflows/zavet-check.yml` | Comments only when a check or guard failed, and deletes its comment once clean | The green check already says it passed. A "passed" table on every PR teaches people to skip bot comments. |
| `.github/workflows/release.yml` | `released`/`version`/`tag`/`tags` outputs come from a tag diff around the `Release` step, never from parsing semantic-release's own output | Tag-diff is stack-agnostic: it works for `modules`, for a custom `release-command`, and needs no cooperation from the caller's `.releaserc`. Adding an output is additive; do not remove or repurpose one without cutting `v2`. |
| `.github/workflows/release.yml` | The `backmerge` job auto-resolves `package.json`, `package-lock.json`, `bun.lock`, `pnpm-lock.yaml`, `yarn.lock` and `CHANGELOG.md` toward the release branch, plus whatever `backmerge-resolve-paths` names, and fails on any other conflict | The shared git plugin's default assets cover every lockfile it might commit, so a real backmerge in a bun or pnpm repo conflicts on more than `package.json`. `backmerge-resolve-paths` covers a caller's own manifest, e.g. one kept in a subdirectory. Widening the built-in list further would resolve a real conflict silently; add a caller path instead. |
| `.github/workflows/release.yml` | The release commit, the tag and the backmerge are pushed with the org App's token whenever `GH_APP_CLIENT_ID` is set, never only with `GITHUB_TOKEN` | The org rulesets that protect `develop` and `main` name the App as their bypass actor. `GITHUB_TOKEN` is not one and cannot be made one, so a push with it is rejected on every protected branch; every develop release in the fleet failed that way for two days in September 2026. The fallback to `GITHUB_TOKEN` exists only for a repo outside the rulesets. |
| all workflows | Callers pin a released tag | `v1` moves only after a change runs green on a real repo. Changing or removing an input is breaking. Add an alias and warn, as `deps-verify` does for `setup:`, or cut `v2`. |
| `README.md` | The onboarding badge says `v1`, and it moves only when the tag it names does | The badge in a consuming repo's README asserts that repo calls these workflows at `@v1`. It is verified against live state by the onboarding tooling, which fails a repo displaying it while its workflows are disabled or its properties unset. Changing the badge's version here without cutting that version is how every onboarded repo starts advertising something untrue at once. |
| `README.md` | The badge names no repo but this one | It is rendered inside repos this org does not control the visibility of, and it is the one artefact from here that a reader outside the org may see in context. Keep its text to what these workflows are, never who uses them. |
| `semantic-release/index.js` | Plugins are handed out as absolute paths, never bare names, and changelog types use `effect`, never `hidden` | A path resolves to this package's copy no matter what config names it or how that config was loaded, where a bare name would not. Preset v10 ignores `hidden` without a warning, so a `docs:` commit leaks into the notes as an untitled bullet. The golden tests fail on either regression. |
| `semantic-release/package.json` | The two beta plugins are pinned exact | Renovate proposes the stable version from an exact prerelease pin and would hide it behind a caret. A consumer gets the bump on the next release here, not as a dependency bump of its own. |
| `release.config.mjs` | Composes from the package by name, and keeps `refactor` from releasing here | The config this repo ships is the one it runs. A release that moves `v1` under every caller for a change with no visible entry is not one to introduce by accident. |
| `actions/semantic-release-config/` | The package is linked from a private prefix, never installed from a registry, and never into the checkout it came with; consumer manifests are never written | A registry needs a token in every consumer, every developer's machine and the Renovate config, and a git dependency cannot point at a subdirectory. An install into the checkout would strip what shares it. |
| `.github/workflows/release.yml` | Runs the link step when `shared-config` is true, and a caller that does not name the package is unaffected | The link sits unused unless the caller's config names it, so adding it was not a rollout, and turning it off silently loses only a registry install nothing there was using. |
| `.github/workflows/supabase-deploy.yml` | Deploys only the `ref` the caller passes (the release job's cut tag), never a trigger of its own; hosted only; the health check fails the job, never warns | A `workflow_run` trigger fires on a no-op release and checks out the wrong commit, so the caller must chain this with `needs:` on its own release job instead. This job holds a Supabase access token, a database password and a live project link, none of which belong on a self-hosted machine other jobs also land on between runs. A health check that only warns lets a deploy that leaves every route erroring report success. |

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
  also calls `setupBranch` and configures git for pushing, where `deps-verify`
  pushes only from its own push step, after checking the commits. That is why `actions/sticky-comment` exists
  instead of `use_sticky_comment`.
- **A non-empty `prompt` puts the action in AGENT mode, which posts nothing.**
  `use_sticky_comment` is read only in tag mode, so setting it beside a prompt is
  a no-op and the report reaches the job summary alone. `run-agent` fails that
  combination and `Self test` catches it at review time. An agent publishes only
  what you tell it to publish, so tell it, then **assert that it did**: both
  workflows fail if the pull request records nothing from the run.
- **`track_progress` forces TAG mode, and tag mode only renders a prompt for
  five events.** `pull_request`, `issues`, `issue_comment`,
  `pull_request_review_comment`, `pull_request_review`, and for `issues` it
  knows three actions: `opened`, `assigned`, `labeled`. Any other event
  (`workflow_dispatch`, a schedule) or any other issue action (`reopened`
  included) throws in Create prompt and fails the job before the agent starts.
  `actions/run-agent` drops the progress comment for those cases and runs in
  agent mode instead, so a reopened issue or a manual dispatch is triaged
  rather than reported red. Narrow either list if upstream narrows; never
  widen it.
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
- **`conventional-changelog-conventionalcommits` v10 renamed `hidden` to
  `effect`.** It does not warn on the old key: a type still carrying `hidden:
  true` is treated as `bump` and shows in the notes anyway. Write `effect:
  "bump" | "hidden"`, never `hidden`.
- **semantic-release loads a plugin from its OWN directory first.** `loadPlugin`
  resolves a name from `semantic-release/lib/plugins`, so a plugin named in a
  top-level config is the copy semantic-release depends on, whatever the
  consumer installed. The one exception is a plugin named by an extended config,
  which loads relative to that config, and `--extends <file>` on the command
  line replaces the config's own `extends` entirely. That is why
  `semantic-release/index.js` hands out every plugin as an absolute path
  instead: a path has none of those conditions, so whatever config names it
  and however it was loaded, the pinned copy is the one that runs. Composing
  needs no `extends` line as a result.
- **A symlink resolves to its real path before Node walks up for
  `node_modules`.** `install.sh` links the consumer's `node_modules` entry to
  a private prefix, not to this checkout, so resolution starts from that
  prefix and the plugins come from there. `--preserve-symlinks` would break
  it by resolving from the link's own location instead.

- **`refactor:` does not release here, so a refactor that changes what callers
  run is not live until a releasing commit follows it.** `release.config.mjs`
  turns the shared `refactor -> patch` rule off on purpose (a tag move with no
  visible entry). A change to a workflow's job graph is a change callers see,
  so type it `perf:` or `fix:` with a body that says what moved, or `v1` stays
  on the old code while `main` looks done.

## Everything here is pinned, including the internal references

The workflows in this repo call each other, and their composite actions, at
`@v1`, the same ref callers outside are told to pin. Otherwise a
`@v1` pin holds the workflow bodies but not the picker and actions they call.

`v1` is moved by semantic-release, not by hand. `release.config.mjs` runs a
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
  `release.config.mjs` if a `1.x` patch will ever be released, because `main` is
  the only release branch today.

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
