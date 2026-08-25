# .github

Org-wide GitHub defaults for `dodi-smart`. Issue templates every repo inherits,
reusable workflows every repo calls, the composite actions those are built from,
and the shared Renovate preset.

A repo here calls a workflow instead of copying one. Its CI becomes a caller file
of about twenty lines, and everything below that line is maintained once, in this
repo, for every repo at the same time.

This repo is **public** because it has to be. A workflow run must be able to read
the workflows it calls, and a public reusable workflow is the ordinary way to do
that across an org. Nothing here is product-specific: no product names, no
hostnames, no secret values.

## Quick start

Add one file to your repo. That is the whole integration.

```yaml
# .github/workflows/pr-checks.yml
name: PR checks
on:
  pull_request:
    branches: [main, develop]

jobs:
  checks:
    uses: dodi-smart/.github/.github/workflows/pr-checks.yml@v1
    with:
      stack: bun
    secrets: inherit
```

That gets you lint, typecheck, test and build on the right runner, with the
package cache set up correctly for that runner, and it stays correct when the
fleet changes.

### What a caller controls

| Part | What it is for |
|---|---|
| `uses:` | Which workflow, pinned to `@v1`. Always pin. |
| `with:` | Inputs. Stack, commands, runner weight, timeouts. |
| `secrets: inherit` | Passes the calling repo's secrets through. Nothing is stored here. |
| `on:` and `concurrency:` | Stay with **you**. Triggers and path filters depend on your branches and layout. |

### Secrets the caller needs

| Secret | Needed for |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | every agent workflow |
| `GH_APP_CLIENT_ID` + `GH_APP_PRIVATE_KEY` | validating the runner selector against the live fleet |

`GH_APP_CLIENT_ID` is the one name for that secret. Migrate a repo still carrying
the older `GH_APP_ID`. Without it the picker cannot read the org runner list, so
it skips validation, and an unvalidated selector that matches nothing looks
exactly like a busy fleet.

## The workflows

| Workflow | Fires on | Does |
|---|---|---|
| `pr-checks.yml` | pull request | Lint, typecheck, test, build, per stack |
| `deps-verify.yml` | Renovate/Dependabot PRs | Builds it, reads upstream changelogs, posts a verdict. Never merges. |
| `pr-review.yml` | `ready_for_review`, `agent:review` | Second-opinion review, deeper on sensitive paths |
| `issue-triage.yml` | issue opened, `agent:triage`, `@claude triage` | Classifies, sets fields, then plans or asks blocking questions |
| `issue-implement.yml` | `agent:implement`, `@claude implement` | Branch, code, draft PR. Requires a plan. Never merges. |
| `claude-assist.yml` | `@claude <anything else>` | The general assistant |
| `release.yml` | push to a release branch | semantic-release, single or multi-module |
| `react-doctor.yml` | pull request, React repos | Static analysis of React/TS source. Advisory by default. |
| `zavet-check.yml` | pull request | Knowledge-layer checks, for repos that have one |
| `pick-runner.yml` | called by the others | Chooses a runner and validates the choice |

### Composite actions

| Action | Purpose |
|---|---|
| `actions/agent-gate` | Decides whether an agent may run. Evaluates `agent:no-touch` first, always. |
| `actions/run-agent` | Invokes the agent with the org's tool allowlist and reporting defaults |
| `actions/setup-stack` | Installs a toolchain, resolves cache isolation, supplies conventional commands |
| `actions/sticky-comment` | One keyed comment per pull request, rewritten in place on every later run |

## What you stop maintaining

Adopting a workflow here removes a class of problem rather than a file.

- **Runner selection.** Ask for `light` or `heavy` and stop naming hardware. When
  the fleet changes, the mapping changes here, once, instead of in every caller
  in every repo.
- **Cache correctness.** Where a package cache lives depends on the runner, the
  job and the stack. `setup-stack` decides it. Getting this wrong costs a day.
- **Agent safety.** The kill switch, the bot rules and the draft rules are one
  implementation with tests, not one `if:` per workflow that drifts.
- **Drift between copies.** A hand-written CI file diverges the moment two repos
  edit it. This is the same file for all of them.
- **Silent breakage.** The picker checks its own selector against the live fleet
  and annotates the run when it matches nothing.

## Two things you can rely on

**`agent:no-touch` stops everything.** Checked before every other condition, in
every agent workflow, with no exemption. Not `workflow_dispatch`, not an explicit
command, not a maintainer. A kill switch that works on only some code paths is
not a kill switch, and position matters as much as existence: a check after an
early return silently stops covering that path. One implementation in
`actions/agent-gate`, with tests across every workflow shape.

**No agent merges anything.** Dependency verification posts a verdict and leaves
merge policy to Renovate's own rules. The implement workflow opens a draft pull
request and stops. Evidence is only useful if it is allowed to be wrong, and
merging on a clean verdict forces conservative tuning, which produces noise,
which gets the report ignored.

## Labels are requests, fields are state

Labels are the only thing that fires a workflow, so they are how you ask. Fields
are queryable across repos, so they are where the answer lives. Each fact sits on
exactly one of them, because two sources for one fact disagree within weeks and
then neither is trusted.

Every `agent:*` label is self-clearing. The workflow removes it when it finishes,
including when it refuses. If it is still there, the work is genuinely running.

```
  agent:triage    -> classify, then plan or ask
  agent:implement -> branch + draft PR   (only when Triage state = Plan ready)
  agent:review    -> review this PR
  agent:no-touch  -> stop everything, no exemptions
```

`agent:implement` does nothing unless the issue is planned. That is a field
comparison in a gate job, run before a runner is picked, with no override. An
agent asked to judge whether a plan is good enough will sometimes accept a
two-line issue body, and the cost is twenty minutes of confident work on the
wrong thing.

## Stacks

The stack is an input, not a separate template: `bun`, `node`, `gradle`,
`android`, `flutter`, `rust`, `xcode`, `none`.

```yaml
with:
  stack: gradle
  install: ""        # "" means this repo has no such step
  build: ./gradlew assembleDebug ktlintCheck
```

`"@stack"`, the default, means that stack's conventional command. `""` means the
step does not exist here. Those are different intentions, and a plain default
cannot express both, because Gradle and Cargo resolve on demand and genuinely
have no install step.

There used to be a caller template per stack. It failed the way templates fail:
the Gradle one carried one product's task name, in a file every other Gradle repo
was told to copy.

### One job or three

`pr-checks.yml` splits light work from heavy by default. `single-job: true`
collapses it onto the heavy runner.

Use it for Gradle. Three jobs mean three configuration phases and no shared
daemon. One job keeps one checkout and one warm `GRADLE_USER_HOME`. The split
stays the right default for a cheap, independent lint.

`env` (newline `KEY=VALUE`) reaches every command step, which is where build
tuning like `GRADLE_OPTS` belongs. `build-env` still applies to the build step
alone.

```yaml
with:
  stack: android
  single-job: true
  lint: ""
  typecheck: ""
  test: ""
  build: ./gradlew --build-cache --parallel assembleDebug ktlintCheck --continue
  env: |
    GRADLE_OPTS=-Dorg.gradle.daemon=false -XX:MaxMetaspaceSize=512m
  coverage: kover
  coverage-path: app/build/reports/kover/reportDebug.xml
```

### Caches

`setup-stack` resolves the mode from `isolate`, `cache` and the runner:

- **Verification jobs isolate.** `deps-verify` pins caches to `RUNNER_TEMP` with
  GitHub cache off, because a verification job that can see yesterday's tree is
  not verifying.
- **Self-hosted uses home dirs**, so the per-runner named volumes are actually
  read. GitHub cache stays off there.
- **`~/.pub-cache` is job-scoped in every mode.** A home dir is only worth using
  if a volume backs it, and the image mounts none for pub.
- **Hosted uses one mechanism per stack**, `setup-gradle` / `rust-cache` /
  `flutter-action`. Never a package store, and never `restore-keys` on one, which
  is how a partial tarball comes back on every retry.

**Never cache a project build directory.** Not `build/`, not `*/build`, not
`.gradle`. `*/build/intermediates` holds absolute paths and the workspace root is
not stable between runners, so AGP rejects its own inputs. A per-SHA key also
misses on every commit by construction, then falls through `restore-keys` to
whatever another branch left behind. It surfaces as a compile error in a file the
pull request never touched. Reuse of compiled output is the build tool's job, by
content hash, and `setup-stack` already wires it up.

## Runners

`pick-runner.yml` takes a semantic `weight` and resolves it:

| `weight` | Selector | Use |
|---|---|---|
| `light` | `self-hosted,Linux,light` | lint, typecheck, checks, releases, reading a diff |
| `heavy` | `self-hosted,Linux,large` | builds, Docker, full suites |
| `apple` | `self-hosted,macOS,ARM64` | Apple toolchain, signing |
| `hosted` | none | forces `hosted-runner`, `ubuntu-latest` by default |

Selectors name capability labels, never an architecture and never a machine name.
A runner of any arch that joins a pool is picked up with no change here, and a
machine name would not survive re-registration.

`light` and `heavy` are tiers of intent, so ask for the one that describes your
work. They stay apart even when one pool could serve both, because re-tiering is
then two lines here instead of an audit of every caller.

A selector that cannot be reached falls back to `fallback`, the light pool by
default, so an unreachable large pool costs capacity rather than hosted minutes.
Set `fallback: ubuntu-latest` for a job that must finish even with the whole
fleet offline, because a self-hosted fallback queues instead.

Public repos and fork pull requests **always** get hosted runners, with no way to
opt out. The runner group refuses public repos, and a fork PR would otherwise run
attacker-authored code on our own hardware against a cache the next job inherits.
That path does not read `fallback`.

## Versioning

Pin `@v1`. It is a moving tag, advanced only after a change has run green on a
real repo. A breaking input change cuts `v2` rather than redefining `v1`.

Releases are cut by semantic-release from `main`, so the version comes from the
commit messages. `feat:` opens a minor, `fix:` a patch, and a breaking change
footer a major.

Do not pin `@main`. Every caller used to, which meant one commit here took effect
everywhere at once, with no staging and no way back except another commit while
CI was already broken.

Pinning is also what makes a change testable. `claude-code-action` refuses to run
when the workflow file differs from the default-branch copy, which is a correct
control, since a pull request could otherwise edit the reviewer to exfiltrate its
token. So verify after merging: merge to `main`, verify on one repo pinned to
`main`, then let the tag move.

## Renovate

```json5
{ extends: ["github>dodi-smart/.github"] }
```

`default.json5` carries only what is true of every repo. Ecosystem rules stay in
the repo that has that ecosystem, because a rule matching nothing is worse than
no rule: it reads as coverage.

## Issue templates

| Template | For |
|---|---|
| Bug | Something behaves incorrectly |
| Feature | A capability that does not exist yet |
| Customer request (unrefined) | Raw customer ask. Paste it verbatim and let triage work out the questions. |
| Chore | Maintenance with no user-visible change |

Blank issues stay enabled. The `gh` CLI and agents create bare issues, and
forcing them through a form would break every scripted path.

## Why `.github/.github/`

Not a typo, and not removable. A `uses:` value is `{owner}/{repo}/{path}@{ref}`.
This repo is *named* `.github`, and GitHub requires reusable workflows to live in
`.github/workflows/` of their source repo, so both segments contain it. Composite
actions have no such rule, so they take a single segment:
`dodi-smart/.github/actions/agent-gate@v1`.

## When nothing happens

Check **state** before contents. A `disabled_manually` workflow produces no runs,
no logs and no failures. Every signal a person looks for is absent, which reads
exactly like "nothing needed doing".

```bash
gh api /repos/dodi-smart/<repo>/actions/workflows --jq '.workflows[]|"\(.state)\t\(.name)"'
```

Otherwise: the pull request may change the workflow itself, see Versioning, or
`agent:no-touch` may be set, which is working as intended and is checked before
everything else, so nothing in the log will hint at it.

## Contributing

`Self test` runs on every pull request touching `actions/`, `.github/workflows/`
or the Renovate preset. It asserts the kill switch across every workflow shape,
checks the runner presets against the table above, parses every YAML file,
shellchecks the scripts, validates the Renovate preset, and runs actionlint.

Read `AGENTS.md` before changing anything. If you add a workflow, add its rule to
the table there with the one line that says why, and extend
`actions/agent-gate/test.sh` if it introduces a new gate shape.
