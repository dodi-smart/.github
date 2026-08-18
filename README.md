# .github

Org-wide GitHub defaults for `dodi-smart`: the issue templates every repo
inherits, the reusable workflows every repo calls, the composite actions those
workflows are built from, and the shared Renovate preset.

This repo is **public** because it has to be: a workflow run must be able to read
the workflows it calls, and a public reusable workflow is the ordinary way to do
that across an org. Nothing here is product-specific — no product names, no
hostnames, no secret values.

It is deliberately self-contained. `DODI-nnnnn` citations appear throughout and
refer to decision records kept privately; every one is written next to enough
reasoning to act on without looking it up.

## Quick start

```yaml
# .github/workflows/triage.yml in your repo
name: Triage
on:
  issues: { types: [opened, reopened, labeled] }
  issue_comment: { types: [created] }
jobs:
  triage:
    uses: dodi-smart/.github/.github/workflows/issue-triage.yml@v1
    secrets: inherit
```

Required secrets on the calling repo:

| Secret | Needed for |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | every agent workflow |
| `GH_APP_CLIENT_ID` + `GH_APP_PRIVATE_KEY` | validating the runner selector against the live fleet |

`GH_APP_CLIENT_ID` is the one name for that secret. Repos carrying the older
`GH_APP_ID` should be migrated: upstream deprecated `app-id` in favour of
`client-id`, and without it the runner picker cannot read the org runner list, so
it skips validation — and an unvalidated selector that matches nothing looks
exactly like a busy fleet (DODI-00012).

## Reusable workflows

| Workflow | Fires on | Does |
|---|---|---|
| `issue-triage.yml` | issue opened · `agent:triage` · `@claude triage` / `@claude plan` | Classifies, labels areas, sets fields, then plans **or** asks blocking questions |
| `issue-implement.yml` | `agent:implement` · `@claude implement` | Branch, code, **draft PR**. Requires a plan. Never merges. |
| `pr-review.yml` | `ready_for_review` · `agent:review` | Second-opinion review, deeper on sensitive paths |
| `deps-verify.yml` | Renovate/Dependabot PRs | Builds, reads upstream changelogs, posts a verdict. **Never merges.** |
| `claude-assist.yml` | `@claude <anything else>` | The general assistant |
| `pr-checks.yml` | pull request | Lint, typecheck, test, build — per stack |
| `release.yml` | push to a release branch | semantic-release, single- or multi-module |
| `zavet-check.yml` | pull request | Knowledge-layer checks, for repos that have one |
| `pick-runner.yml` | called by the others | Chooses a runner and validates the choice |

## Composite actions

| Action | Purpose |
|---|---|
| `actions/agent-gate` | Decides whether an agent may run. Evaluates `agent:no-touch` first, always |
| `actions/run-agent` | Invokes the agent with the org's tool allowlist and reporting defaults |
| `actions/setup-stack` | Installs a toolchain, resolves cache isolation, supplies conventional commands |

## Two things you can rely on

**`agent:no-touch` stops everything.** It is checked before every other
condition, in every agent workflow, with no exemption — not `workflow_dispatch`,
not an explicit command, not a maintainer. A kill switch that works on only some
code paths is not a kill switch, and position matters as much as existence: a
check placed after an early return silently stops covering that path. It is one
implementation in `actions/agent-gate`, with tests covering every workflow shape
(DODI-00008).

**No agent merges anything.** Dependency verification posts a verdict and leaves
merge policy to Renovate's own rules; the implement workflow opens a draft PR and
stops. Evidence is only useful if it is allowed to be wrong, and merging on a
clean verdict forces conservative tuning, which produces noise, which gets the
report ignored (DODI-00004, DODI-00019).

## Labels are requests; fields are state

Labels are the only thing that fires a workflow, so they are how you *ask*.
Fields are queryable across repos, so they are where the answer *lives*. Each
fact sits on exactly one of them, because two sources for one fact disagree
within weeks and then neither is trusted (DODI-00001).

Every `agent:*` label is **self-clearing**: the workflow removes it when it
finishes, including when it refuses. If it is still there, the work is genuinely
running.

```
  agent:triage    ─► classify, then plan or ask
  agent:implement ─► branch + draft PR   (only when Triage state = Plan ready)
  agent:review    ─► review this PR      (or re-verify a dependency PR)
  agent:no-touch  ─► stop everything, no exemptions
```

`agent:implement` does nothing unless the issue is planned. That check is a field
comparison in a gate job, run before a runner is picked, with no override — an
agent asked to judge whether a plan is good enough will sometimes accept a
two-line issue body, and the cost is twenty minutes of confident work on the
wrong thing plus a PR someone must read to discover it was wrong (DODI-00019).

## Stacks

The stack is an **input**, not a separate template:
`bun`, `node`, `gradle`, `android`, `flutter`, `rust`, `xcode`, `none`.

```yaml
with:
  stack: gradle
  install: ""        # "" means this repo has no such step
  build: ./gradlew assembleDebug ktlintCheck
```

`"@stack"` (the default) means that stack's conventional command; `""` means the
step does not exist here. Those are different intentions — Gradle and Cargo
resolve dependencies on demand and genuinely have no install step — and a plain
default cannot express both.

There used to be a caller template per stack. It failed the way templates fail:
the Gradle one carried one product's Gradle task name, in a file every other
Gradle repo was told to copy (DODI-00015).

Package caches are **not** always job-scoped. `setup-stack` resolves three
modes from `isolate`, `cache`, `runner.environment`, `runner.os` and
`runner.arch` (DODI-00020):

- `isolate: true` (deps-verify) and the self-hosted **Linux** ARM64 pool pin
  caches to `RUNNER_TEMP` and disable GitHub cache — verification must not see
  yesterday's tree, and a Pi with 8 GB must not grow bun/Gradle volumes. The
  check is Linux ARM64, not ARM64: the self-hosted Mac is ARM64 too, has no
  container volumes to grow, and gains nothing from running every job cold.
- Self-hosted X64 uses default home dirs (`~/.bun`, `~/.npm`, `~/.cache/pnpm`,
  `~/.gradle`, `~/.cargo`) so per-runner named volumes are actually read.
  GitHub cache stays off.
- `~/.pub-cache` is job-scoped in **every** mode. A home dir is only worth
  using if a volume backs it, and the runner image mounts none for pub — so on
  a persistent runner it would grow in the container layer, outside the
  post-job LRU cap that bounds every other store.
- GitHub-hosted uses those same home dirs; `cache: auto` becomes true for
  `setup-gradle` / `rust-cache` / `flutter-action` only. Bun is never
  uploaded. One mechanism per stack — never *also* `setup-java cache: gradle`,
  never `restore-keys` on a package store. That pairing is how a partial
  tarball came back on every retry.

## Runners

`pick-runner.yml` takes a semantic `weight` and resolves it:

| `weight` | Selector | Hardware |
|---|---|---|
| `light` | `self-hosted,Linux,ARM64` | small pool — lint, typecheck, releases, reading a diff |
| `heavy` | `self-hosted,Linux,X64` | large pool — builds, Docker, full suites |
| `apple` | `self-hosted,macOS,ARM64` | Apple toolchain, signing |
| `hosted` | — | forces `ubuntu-latest` |

Public repos and fork PRs **always** get hosted runners, with no way to opt out:
the runner group refuses public repos, and a fork PR would otherwise run
attacker-authored code on our own hardware against a cache that persists into the
next job (DODI-00010).

The picker validates its selector against the live fleet and annotates the run
when it matches nothing. That check matters more than the sharing does: falling
back to hosted on error is correct behaviour, but it makes a selector matching
nothing indistinguishable from a busy fleet — both produce a successful hosted
run, with no signal to notice. An org-wide selector asking for a label no runner
carried survived months that way (DODI-00012).

## Versioning

Pin `@v1`. It is a moving tag, advanced only after a change has run green on a
real repo. A breaking input change cuts `v2` rather than redefining `v1`.

Do not pin `@main`. Every caller used to, which meant one commit here took effect
in every repo simultaneously, with no staging step and no way to roll back except
another commit while CI was already broken everywhere (DODI-00017).

It also gives workflow changes a way to be tested at all: `claude-code-action`
refuses to run when the workflow file differs from the default-branch copy — a
correct control, since a PR could otherwise edit the reviewer to exfiltrate its
token — so a change can only be verified *after* merging. Merge to `main`, verify
on one repo pinned to `main`, then move `v1` (DODI-00013).

## Renovate

```json5
{ extends: ["github>dodi-smart/.github"] }
```

`default.json5` carries only what is true of every repo. Ecosystem rules stay in
the repo that has that ecosystem, because a rule matching nothing is worse than
no rule — it reads as coverage.

## Issue templates

| Template | For |
|---|---|
| Bug | Something behaves incorrectly |
| Feature | A capability that does not exist yet |
| Customer request (unrefined) | Raw customer ask — paste it verbatim and let triage work out the questions |
| Chore | Maintenance with no user-visible change |

Blank issues stay enabled: the `gh` CLI and agents create bare issues, and forcing
them through a form would break every scripted path.

## Why `.github/.github/`

Not a typo, and not removable. A `uses:` value is `{owner}/{repo}/{path}@{ref}`.
This repo is *named* `.github`, and GitHub requires reusable workflows to live in
`.github/workflows/` of their source repo — so both segments contain it. The same
shape appears wherever a `.github` repo hosts shared CI:

```yaml
uses: stylelint/.github/.github/workflows/call-lint.yml@ab79793
uses: craftcms/.github/.github/workflows/ci.yml@v3
```

`dodi-smart/.github/workflows/...` would resolve to a file at `workflows/` in the
repo root, which GitHub will not accept. Composite actions have no such rule, so
they are referenced with a single segment:
`dodi-smart/.github/actions/agent-gate@v1`.

## When nothing happens

Check **state** before contents. A `disabled_manually` workflow produces no runs,
no logs and no failures — every signal a person looks for is absent, which reads
exactly like "nothing needed doing". Six workflows across three repos sat that way
for five months (DODI-00007).

```bash
gh api /repos/dodi-smart/<repo>/actions/workflows --jq '.workflows[]|"\(.state)\t\(.name)"'
```

Otherwise: the PR may change the workflow itself (see Versioning), or
`agent:no-touch` may be set — which is working as intended, and is checked before
everything else, so nothing in the log will hint at it.

## Contributing

`Self test` runs on every PR touching `actions/`, `.github/workflows/` or the
Renovate preset. It asserts the kill switch across every workflow shape, parses
every YAML file, shellchecks the scripts, validates the Renovate preset, and runs
actionlint.

If you add a workflow, add its governing decision ids to `AGENTS.md` with the
reasoning written out, and extend `actions/agent-gate/test.sh` if it introduces a
new gate shape.
