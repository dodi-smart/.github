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
| `GH_APP_CLIENT_ID` + `GH_APP_PRIVATE_KEY` | the App token other workflows mint (release pushes, deps-verify). The runner picker no longer uses them |
| `AGENT_ENV_SECRET` | optional; secret env for every agent run, see [Org additions to agent runs](#org-additions-to-agent-runs) |

`GH_APP_CLIENT_ID` is the one name for that secret. Migrate a repo still carrying
the older `GH_APP_ID`. The runner picker is static and makes no API call, so it
needs no token; `pick-runner.yml` still accepts the two secrets so an existing
caller keeps working.

## The workflows

| Workflow | Fires on | Does |
|---|---|---|
| `pr-checks.yml` | pull request | Lint, typecheck, test, build, per stack |
| `deps-verify.yml` | Renovate/Dependabot PRs | Reads the PR checks result, reads upstream changelogs, fixes code the update broke, posts a one-comment verdict. Never merges. |
| `deps-automerge.yml` | verdict labels, `review / verdict`, `renovate/stability-days`, PR Checks done | Merges a dependency bot's minor, patch or lock file PR once it is `deps:verified`, or `deps:fixed` and approved, and the required check is green. No agent |
| `pr-review.yml` | `ready_for_review`, `agent:review` | Second-opinion review, deeper on sensitive paths. Publishes the `review / verdict` status and a `review-verdict.json` artifact |
| `issue-triage.yml` | issue opened or reopened, `agent:triage`, `@claude triage`, manual dispatch with `issue-number` | Classifies, sets fields, then plans or asks blocking questions |
| `issue-implement.yml` | `agent:implement`, `@claude implement` | Holdout tests from the plan's acceptance criteria, then code. A step pushes one commit to `feat\|fix\|chore/<n>-<slug>` and opens a draft PR. Requires a plan. |
| `pr-iterate.yml` | `agent:iterate`, PR Checks completed, the review verdict status | The agent fix loop: up to 3 fix rounds on red checks or a `changes` verdict, then ready for review, then a rebase merge when the issue is `Autonomous` with Risk and Effort `Low`. Every push, ready and merge is a step, not the agent. A Renovate or Dependabot PR stops, label or not: deps-verify owns it |
| `claude-assist.yml` | `@claude <anything else>` | The general assistant |
| `release.yml` | push to a release branch | semantic-release, single or multi-module |
| `supabase-deploy.yml` | called after `release.yml` | Pushes a Supabase project's schema and functions for the tag a release just cut |
| `android-deploy.yml` | called after `release.yml` | Builds the signed release APK for the tag a release just cut, attaches it to the GitHub Release and, if asked, distributes it through Firebase App Distribution. Signing material comes from 1Password |
| `react-doctor.yml` | pull request, React repos | Static analysis of React/TS source. Advisory by default, on a pinned React Doctor version that Renovate bumps here (`version` overrides it). `pr-checks.yml` can run it as a job instead (`react-doctor: true`) |
| `zavet-check.yml` | pull request | Knowledge-layer checks, for repos that have one. Report-only on dependency and automation bot PRs. `pr-checks.yml` can run it as a job instead (`zavet: true`) |
| `supabase-checks.yml` | pull request, Supabase repos | Deno edge-function check, generated-types check, pgTAP tests, and an opt-in squawk lint of the migrations a pull request changed. The jobs that start Postgres are hosted only; the lint runs on the light pool |
| `pick-runner.yml` | called by the others | Resolves a runner weight to a `runs-on` selector. Static: no API call, no token |

`release.yml` reports what it did through `workflow_call` outputs, so a caller
can chain a deploy job on an actual release rather than a green job:

| Output | Meaning |
|---|---|
| `released` | `'true'` when at least one new version tag was pushed, `'false'` otherwise |
| `version` | Newest released version, without the `v` prefix (e.g. `1.4.0`) |
| `tag` | Newest released tag (e.g. `v1.4.0`) |
| `tags` | JSON array of ALL new tags this run, for multi-module repos |

They come from a tag diff taken around the release step, not from parsing
semantic-release's own output, so they work the same way whether the caller
uses `modules` or a custom `release-command`.

`release.yml` can also merge a release branch back into a prerelease branch:

| Input | Default | Meaning |
|---|---|---|
| `backmerge` | `false` | Merge `backmerge-from` into `backmerge-to` after releasing |
| `backmerge-from` | `"main"` | Branch the release was cut from |
| `backmerge-to` | `"develop"` | Prerelease branch to merge into |
| `backmerge-resolve-paths` | `""` | Extra paths to auto-resolve toward `backmerge-from` on conflict, newline- or space-separated (e.g. a subdirectory manifest and its lockfile) |

A stable release after a prerelease always conflicts on the files both commits
rewrote, so the job auto-resolves `package.json`, `package-lock.json`,
`bun.lock`, `pnpm-lock.yaml`, `yarn.lock` and `CHANGELOG.md` toward
`backmerge-from` and fails on any other conflict. `backmerge-resolve-paths`
extends that list; it does not replace it.

The backmerge is the last step of the `release` job, not a job of its own, so
it reuses that job's token and checkout. It fetches `backmerge-from` again
before merging, and a failed backmerge fails the job, so a caller chaining a
deploy on `release.yml` starts it after the backmerge.

When it drives semantic-release itself (no `release-command`), `release.yml`
installs the tooling into a private prefix under `RUNNER_TEMP`, never into the
checkout, so the caller's own dependency tree is not installed alongside it.
`semantic-release-packages` empty (the default) installs the versions pinned in
`actions/release-tooling`, from a lockfile, cached on its hash. A list there
replaces that set and installs exactly those packages, unpinned.

### Release, then deploy

`supabase-deploy.yml` is not triggered on its own. It is a job the caller
chains on `release.yml` with `needs:`, gated on `release.yml`'s outputs, so it
deploys the tag a release actually cut rather than the push that started the
run:

```yaml
jobs:
  release:
    uses: dodi-smart/.github/.github/workflows/release.yml@v1
    secrets: inherit

  deploy:
    needs: release
    # Production: only a cut, non-prerelease tag on main.
    if: ${{ !cancelled() && needs.release.outputs.released == 'true' && github.ref == 'refs/heads/main' && !contains(needs.release.outputs.tag, '-') }}
    uses: dodi-smart/.github/.github/workflows/supabase-deploy.yml@v1
    with:
      ref: ${{ needs.release.outputs.tag }}
      cli-version: 2.117.0 # renovate: datasource=npm depName=supabase
      environment: production
    secrets:
      SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
      SUPABASE_DB_PASSWORD:  ${{ secrets.SUPABASE_DB_PASSWORD }}
      SUPABASE_PROJECT_ID:   ${{ secrets.SUPABASE_PROJECT_ID }}
```

A staging caller drops the `released` clause from the `if:` and deploys on
every push to its branch instead, since staging has nothing to gate on a
release output for.

Do not reach for `on: workflow_run: { workflows: ["Release"] }` instead. It
fires on completion, including a run that released nothing, so a no-op release
run still triggers a deploy of whatever HEAD happens to be at that moment. And
by default it checks out the SHA that started the original run, not the tag
`@semantic-release/git` pushes afterwards, so a `workflow_run`-triggered deploy
ships the commit *before* the release it is meant to deploy. Chaining with
`needs:` inside the same run is what makes the actual tag available as an
output at all.

`cli-version` is not defaulted by this workflow. A default here is a version
Renovate cannot see, so the CLI would upgrade itself with no diff for anyone to
review. Pin it in the caller with a Renovate regex-manager comment, as in the
example above, so a CLI release opens a normal pull request instead of taking
every project's next deploy down at once, the way an undetected `supabase/cli`
regression once did.

#### Inputs

| Input | Default | Meaning |
|---|---|---|
| `ref` | *(required)* | Tag or sha to check out and deploy |
| `cli-version` | *(required)* | Supabase CLI version, pinned and Renovate-marked in the caller |
| `environment` | `""` | Name of a GitHub environment configured in the caller's repo. Empty means no environment: no protection rules, no environment secrets |
| `seed` | `false` | Pass `--include-seed` to `supabase db push` |
| `functions` | `true` | Deploy `supabase/functions` when it holds anything; `false` skips it even if it does |
| `health-url` | `""` | Base URL to probe after deploy. Empty skips the health check entirely |
| `health-routes` | `"/"` | Space-separated routes appended to `health-url` |
| `health-attempts` | `6` | Retries before the health check fails the job |
| `health-wait-environment` | `""` | Wait for a successful GitHub Deployment of the deployed commit in this environment before probing. See below |
| `health-sha-route` | `""` | Route on `health-url` whose body carries the deployed commit's sha. The other proof, for a host that posts no Deployments |
| `health-wait-timeout-minutes` | `10` | How long the whole wait may take before the job fails |
| `timeout-minutes` | `15` | Job timeout. Raise it to cover `health-wait-timeout-minutes` plus the deploy itself |

#### Secrets

| Secret | Required | Meaning |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | yes | Supabase CLI auth |
| `SUPABASE_DB_PASSWORD` | yes | Non-interactive `supabase link` / `db push` |
| `SUPABASE_PROJECT_ID` | yes | The project ref to link and deploy against |
| `FUNCTION_SECRETS` | no | Multiline `KEY=value`, one per line, passed to `supabase secrets set`. Built by the caller from its own secrets (`FUNCTION_SECRETS: \|` followed by `NAME=${{ secrets.NAME }}` lines) — nothing here is hard-coded with a function secret's name or value. Unset skips the step entirely |

The health check FAILS the job after `health-attempts`, deliberately: a deploy
that leaves every route erroring must not go green. A warning-only check is
strictly worse than no check, because it reads as a passing signal that
nobody then goes back to question.

#### What the health check proves

On its own, only that `health-url` answers. A frontend host builds the same push
in parallel with this job and moves its stable URL when its own build ends, so a
check that runs right after `db push` usually reaches the deployment that was
already live. With neither wait input set, the job prints a notice saying so.

Set one, and the check waits for this commit first:

- `health-wait-environment` polls the repository's GitHub Deployments for the
  deployed commit in that environment, and continues on a `success` status. A
  `failure` or `error` status, or `health-wait-timeout-minutes` passing, fails
  the job. Hosts post these as their build progresses. The deployment this job's
  own `environment:` creates is ignored, since it succeeds when the job does.
  The token needs `deployments: read`; a caller that narrows `permissions:` must
  keep it.
- A release commit carries `[skip ci]`, which hosts honour, so the host builds
  the commit before it. When the deployed commit's message asks CI to skip it,
  the deployment of its parent counts too.
- `health-sha-route` is the fallback for a host without Deployments. The caller
  exposes a route that returns the commit sha, and the wait passes when the body
  contains the first seven characters of the deployed commit or of its parent
  under the same rule.
- The routes are then probed at `health-url`.

The log shows the deployment id and commit before the routes are probed.

### Release, then deploy an Android build

`android-deploy.yml` follows the same shape as `supabase-deploy.yml`: a job the
caller chains on `release.yml` with `needs:`, so it builds the tag a release
actually cut:

```yaml
jobs:
  release:
    uses: dodi-smart/.github/.github/workflows/release.yml@v1
    secrets: inherit

  deploy:
    needs: release
    if: ${{ !cancelled() && needs.release.outputs.released == 'true' && github.ref == 'refs/heads/main' && !contains(needs.release.outputs.tag, '-') }}
    uses: dodi-smart/.github/.github/workflows/android-deploy.yml@v1
    permissions:
      contents: write
    with:
      tag: ${{ needs.release.outputs.tag }}
      op-keystore:             op://<vault>/<item>/keystore.jks
      op-store-password:       op://<vault>/<item>/store-password
      op-key-alias:            op://<vault>/<item>/key-alias
      op-key-password:         op://<vault>/<item>/key-password
      op-firebase-credentials: op://<vault>/<item>/service-account.json
      firebase-app-id:         1:000000000000:android:0000000000000000
      firebase-groups:         testers
      environment: production
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
      GH_APP_CLIENT_ID:         ${{ secrets.GH_APP_CLIENT_ID }}
      GH_APP_PRIVATE_KEY:       ${{ secrets.GH_APP_PRIVATE_KEY }}
```

The called job needs `contents: write` to upload to the release, and a called
job cannot hold more than its caller grants, so a caller that narrows
`permissions:` grants it on the `deploy` job as above.

Everything product-specific comes from the caller: the 1Password references,
the Firebase app and groups, the Gradle task and the APK glob. Nothing about
the app is written in this repo.

The job checks out the tag with its full history, installs the Android toolchain
(and Node when it distributes), loads the signing material from 1Password, runs `./gradlew
<gradle-task>` with Android Gradle Plugin's injected signing, attaches the APKs
to the release (`--clobber`, so a re-run replaces them), then distributes. The
release notes are the GitHub Release's body. An empty body becomes `Release
<tag>`, and a body over 8000 bytes is cut and points at the Release.

#### Inputs

| Input | Default | Meaning |
|---|---|---|
| `tag` | *(required)* | Tag to build and attach to. Pass `needs.release.outputs.tag` |
| `op-keystore` | *(required)* | 1Password reference of the keystore file |
| `op-store-password` | *(required)* | Reference of the keystore password |
| `op-key-alias` | *(required)* | Reference of the key alias |
| `op-key-password` | *(required)* | Reference of the key password |
| `op-firebase-credentials` | `""` | Reference of the Firebase service-account JSON. Required with `firebase-app-id` |
| `firebase-app-id` | `""` | Firebase app id. Empty builds, signs and attaches the APKs and distributes nothing |
| `firebase-groups` | `""` | Comma-separated tester group aliases. Empty uploads the build to nobody |
| `gradle-task` | `assembleRelease` | Run as `./gradlew <gradle-task>`, split on spaces |
| `apk-glob` | `**/build/outputs/apk/release/*.apk` | Newline-separated globs of the built APKs. Zero matches fails; an APK with `unsigned` in its name is ignored; every match is attached, but Firebase takes one, so more than one fails the distribution after the upload |
| `env` | `""` | Newline-separated `KEY=VALUE` applied to the build through setup-stack, parsed as in `pr-checks.yml`. Tuning and placeholders only, never secrets |
| `environment` | `""` | A GitHub environment in the caller's repo, as in `supabase-deploy.yml`. Empty means none |
| `timeout-minutes` | `45` | Job timeout |

#### Secrets

| Secret | Required | Meaning |
|---|---|---|
| `OP_SERVICE_ACCOUNT_TOKEN` | yes | 1Password service account that can read the references above |
| `GH_APP_CLIENT_ID`, `GH_APP_PRIVATE_KEY` | no | The org App. The release upload uses its token when both are set and the job's own token otherwise |

#### Where it runs, and what happens to the secrets

The job takes the heavy pool of a private repository and a hosted runner for a
public one or a fork. That differs from `supabase-deploy.yml`, which stays
hosted because a self-hosted machine is one other jobs also land on. An Android
release build needs the heavy pool's memory, so the secrets are confined
instead. The build is isolated: its own Gradle home under `RUNNER_TEMP`, no
daemon, and no cache a pull request build wrote. The keystore and the Firebase
credentials are written to a fresh `0700` directory under `RUNNER_TEMP`, never
the workspace, and the passwords reach Gradle through a `gradle.properties` in
the isolated home, never as arguments. The last step deletes both with
`if: always()`, and 1Password values are masked in the log. The 1Password action is pinned to a commit SHA, since a moved tag
would run with the service-account token.

`firebase-tools` is pinned to an exact version in the workflow, behind a
Renovate marker, and a bump releases as `chore(deps)`.

### Composite actions

| Action | Purpose |
|---|---|
| `actions/agent-gate` | Decides whether an agent may run. Evaluates `agent:no-touch` first, always. |
| `actions/run-agent` | Invokes the agent with the org's tool allowlist and reporting defaults, on the model `actions/pick-model` chooses for its `stage`. Does not start it when the running workflow file differs from the default branch, says why a run stopped (`why`), and with `report-file` guarantees a valid report file on every path |
| `actions/pr-facts` | Resolves the PR from a number or a pull_request, workflow_run or status event, and checks it is open, not a fork, and at the expected head |
| `actions/request-review` | Applies `agent:review` with the App token when the head commit has no `review / verdict` yet |
| `actions/merge-gate` | The one unattended merge: resolves the PR, runs `agent-gate`, decides by policy (`deps` or `factory`) from labels, the required check, `review / verdict`, Renovate's release-age status, mergeability and commit authors, and merges with the App token. A conflicted Renovate PR gets its rebase box ticked instead |
| `actions/push-round` | Checks an agent's commits on a PR branch, regenerates lockfiles, and pushes them as one trailered commit with the App token, or refuses with a reason |
| `actions/app-token` | Mints the org App token for this repo, optionally narrowed; empty when no App is configured |
| `actions/factory` | The deterministic half of `issue-implement.yml` and `pr-iterate.yml`: the autonomy tier from `Agent mode`, `Risk` and `Effort`, the branch name, round 0's push, the holdout pattern fix rounds give `push-round` (one list per issue, `.factory/holdout.d/<issue>`), and the fix loop's next step |
| `actions/setup-stack` | Installs a toolchain, resolves cache isolation, supplies conventional commands |
| `actions/sticky-comment` | One keyed comment per pull request, rewritten in place on every later run |
| `actions/deps-intent` | Decides from a dependency PR's diff whether `deps-verify.yml` has anything new to judge. Internal to that workflow |
| `actions/release-tooling` | Installs semantic-release and its default plugins from a pinned lockfile into a private prefix, cached on the lockfile hash, and puts `semantic-release` on `PATH` |
| `actions/semantic-release-config` | Links the shared semantic-release config into a consumer's `node_modules` from a private prefix, never from a registry and never into the checkout it came with |
| `actions/lcov-report` | Overall and changed-file line coverage from an LCOV file, posted as a sticky comment, with optional floors. What `pr-checks.yml`'s `coverage: lcov` calls |
| `actions/bundle-report` | First-load JS per route and in total (gzip) from a Next.js build's manifests, compared with a default-branch report and posted as a sticky comment, with an optional growth limit. Reads Turbopack and webpack builds alike |
| `actions/hk-check` | Installs the repo's mise tools, runs `hk check --all --sarif`, appends the output to the job summary, warns on a SARIF file that is not valid JSON, and keeps the SARIF as an artifact. What `pr-checks.yml`'s `hk: true` runs |
| `actions/changed-files` | A pull request's changed files through the API, with no checkout, and whether any, or every one, match a set of globs. Pure bash: it needs `gh` and nothing else |
| `actions/migration-lint` | Lints the `*.sql` migrations a pull request added or changed with a pinned squawk, as annotations. Advisory unless `blocking: true`; squawk failing to install or run always fails it. What `supabase-checks.yml`'s `migration-lint` job calls. The caller checks out first |
| `actions/runner-report` | Writes which runner a job got (name, pool, labels, OS, image, queue time) to the job summary and a notice, or with `mode: run` a "Where it ran" table for every job of the run. Needs `actions: read` for queue time; without it the runner is still named. Never fails the job |
| `actions/run-phases` | Runs a job's install, lint, design-lint, typecheck, test, build and smoke commands as timed phases, each in its own shell, and writes a timing and peak-memory table to the job summary. `log-dir` also writes each phase's output to a file; `keep-going: true` runs every phase and the `failed` output lists the ones that failed. The `peak-rss` output is the largest per-phase peak memory in MiB. What `pr-checks.yml` and `deps-verify.yml` run their commands with |
| `actions/wait-for-deployment` | Waits for the frontend host's successful GitHub Deployment of the checked-out commit, or for a route to report its sha. What `supabase-deploy.yml`'s health check calls |
| `actions/supabase-start` | Starts the local Supabase database with the stack's Docker images restored from the cache, saved on a miss. What both jobs of `supabase-checks.yml` call |
| `actions/android-distribute` | The steps after a signed Android build: resolves the APK glob (an unsigned APK never counts), attaches every APK to the tag's GitHub Release, and hands one to Firebase App Distribution with the Release body as its notes. What `android-deploy.yml` runs |
| `actions/zavet-check` | Verifies a repo's `.zavet/` knowledge layer: decision checks, guard trailers, an optional audit, and a comment only on failure. What `zavet-check.yml` and `pr-checks.yml`'s `zavet` job run. The caller checks out with full history first. |
| `actions/react-doctor` | Checks out with full history and runs React Doctor. What `react-doctor.yml` and `pr-checks.yml`'s `react-doctor` job run. |
| `actions/pick-model` | The model policy as one script, `pick.sh`: an agent stage, the issue's Effort, Priority and Risk, and the run's signals in, a model id and a turn cap out. run-agent runs it on every agent run; see [Models](#models). |
| `actions/pick-runner` | Resolves a runner weight to a selector, statically: no API call, no token, no fleet listing. What `pick-runner.yml` calls, and what a job that already exists (like `pr-checks.yml`'s `pick`) calls directly to pick more than once without another job. |

`actions/changed-files` needs no checkout. It takes `patterns` (newline-separated
paths or globs, `fnmatch`-style, so `*` crosses `/`; a pattern also matches everything under it),
and outputs `files` (one path per line, a rename under both names), `matched`
and `all-matched`. Skip work only when `matched` is `false`. It is `true`
whenever the answer cannot be known. That covers an event that is not a pull
request, no `patterns`, an empty or unreadable list, and a list at the API's
3000-file cap, which is cut off. `all-matched` is the opposite claim, for a
skip that needs every file inside the paths (a docs-only change): it is `true`
only when the whole list was read and every file matches, and `false` on every
one of those doubts. Skip work on `all-matched` only when it is `true`.
`complete` is for a caller that works from `files` itself: `true` only when the
whole list was read (a pull request, no API error, not empty, below the cap),
whatever `patterns` is. The token needs `pull-requests: read`.

```yaml
- id: changes
  uses: dodi-smart/.github/actions/changed-files@v1
  with:
    patterns: |
      db/*
      **.sql
- if: steps.changes.outputs.matched == 'true'
  run: ./heavy-check.sh
```

**`agent-gate` inputs and outputs a caller may use beyond the basics.**

| Name | Meaning |
|---|---|
| input `bots` | `reject` (default): stop on any non-human author. `only`: proceed for dependency bots only. `allow`: ignore the author. |
| input `number` | Override for the issue or PR number. The gate reads it from the event payload, so set it only where the payload has none (a `workflow_dispatch`). Before a run proceeds, the gate reads the item's current labels and stops on `agent:no-touch` added after the event. A failed read warns and proceeds. Needs `issues: read` or `pull-requests: read` on the gate job. |
| input `events` | Space-separated `github.event_name` values the workflow handles, checked right after `agent:no-touch`. Any other event stops the run. Empty (default) allows every event. `issue-triage.yml` passes `issues issue_comment workflow_dispatch`, so a person's PR review never reaches it. |
| output `author-kind` | `dependency` (Renovate, Dependabot), `agent` (`claude[bot]`), `automation` (any other `[bot]` or `app/` login) or `human`. Written before every rule, `agent:no-touch` included, so it is set on a stopped run too. A workflow that needs only the classification can call the gate for it and ignore `proceed`; a script runs `gate.sh kind LOGIN`. |
| output `dependency-bots` | The comma-separated dependency-bot logins, for `claude-code-action`'s `allowed_bots`. `deps-verify.yml` reads it. |

The dependency-bot list lives in `actions/agent-gate/gate.sh` and nowhere else.

**`sticky-comment` delete mode.** `delete: true` finds the comment for `key`
(bot-authored only, like an update) and deletes it, or does nothing when there
is none. It needs no `body-file`. The `action` output is `deleted` or `none`.
`zavet-check.yml` uses it to retract its comment once a pull request is clean.

**`zavet-check.yml` and automation PRs.** A dependency or automation bot's pull
request is report-only; `claude[bot]` and people still fail closed. An
automation that opens PRs with `GITHUB_TOKEN` triggers no pull request workflows
at all, so nothing here would run on its PR. Open them with the org App token
(`actions/create-github-app-token`) instead.

**`actions/zavet-check`: lazy install and promotion PRs.** Nothing is installed
unless a decision or spec declares `checks:` and the CLI is vendored: a repo
whose decisions and specs carry no checks skips `setup-stack` and the install
(yq still installs when the CLI is present, because guards read frontmatter
with it). A declared check with no CLI still fails closed. The
`integration-branch` input (default `develop`, `""` turns it off) names the
branch whose promotion PRs, a same-repo head from that branch into another,
walk no guard commits: they already passed the guard wall on their own pull
requests and are logged as `skip (promotion)`. A commit pushed straight to that
branch is not walked on promotion, so it should require pull requests.

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
- **Silent breakage.** Every job starts with a runner report: which runner it
  landed on, its pool, and how long it queued. A mislabelled or missing pool
  shows up in the job summary, not as a job that waits forever unexplained.

## The badge that brought you here

A repo wired up to these workflows carries this badge in its README:

[![shared workflows v1](https://img.shields.io/badge/shared_workflows-v1-0969da)](https://github.com/dodi-smart/.github)

It is a claim about that repo, so it is worth knowing what backs it. The badge
means the repo calls the workflows above at `@v1`, that those workflows are
`active` rather than sitting disabled, that it carries the shared label set and
an area map, and that its bot configs emit the label names the workflows expect.
An onboarding tool asserts all of it and **fails** the repo if the badge is
present while any of it is not. A badge nobody checks is decoration within one
drift, and worse than none, because it is read as a guarantee by everyone who
does not go and look.

Two org-level repository custom properties carry the same facts in queryable
form:

| Property | Answers |
|---|---|
| `onboarded` | Which generation of these workflows the repo is on: `v1`, or `none` |
| `client` | Which body of work the repo belongs to |

`onboarded` holds a version rather than a yes/no, because the question actually
worth asking is which repos still need migrating, and a version answers it as a
single search instead of an audit. It is required with a default of `none`, so a
repo created next year answers it too rather than being quietly absent from
every count.

Property *values* are visible to org members only. The badge is the public half,
and it deliberately names no repo but this one.

## Two things you can rely on

**`agent:no-touch` stops everything.** Checked before every other condition, in
every agent workflow, with no exemption. Not `workflow_dispatch`, not an explicit
command, not a maintainer. A kill switch that works on only some code paths is
not a kill switch, and position matters as much as existence: a check after an
early return silently stops covering that path. One implementation in
`actions/agent-gate`, with tests across every workflow shape.

**No agent merges anything.** Dependency verification posts a verdict, and may
push a fix commit for code the update broke. The implement workflow opens a
draft pull request and stops. The one thing that merges is `deps-automerge.yml`,
and it is not an agent: a deterministic rule over labels, the required check and
the review status, for minor, patch and lock file updates only. Majors always
wait for a person.

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
comparison in the gate job, which also picks the runner once that comparison
passes, with no override. An agent asked to judge whether a plan is good
enough will sometimes accept a two-line issue body, and the cost is twenty
minutes of confident work on the wrong thing.

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

### Design lint

An optional step for a design-system verifier (oxlint hosting `@shadcn/lint`),
separate from `lint` because it has its own exit code and its own ratchet.
Default `""` means the step does not exist -- every caller pinned at `@v1` is
unaffected until it opts in. No `@stack` default: there is no conventional
command for this, on any stack.

```yaml
with:
  design-lint: bun run lint:design --format=github
```

Warnings are advisory. `--max-warnings N` in the caller's own command is the
ratchet -- tighten it there as the count comes down.

### hk

An opt-in step that runs the caller's own [hk](https://hk.jdx.dev) config over
the whole tree, so the same `hk.pkl` that drives the local git hooks reports in
the shared CI. Default `false`: every caller that never sets it behaves exactly
as before, and no new permission is needed. It sits beside `lint` and replaces
nothing.

```yaml
jobs:
  pr-checks:
    uses: dodi-smart/.github/.github/workflows/pr-checks.yml@v1
    with:
      stack: bun
      hk: true
```

With `hk: true`, `checks` (or `all`, with `single-job`) runs `install`, then
`jdx/mise-action` (which installs the tools the caller's `mise.toml` pins), then
`hk check --all --sarif hk.sarif`, then the remaining phases. `--all`, never
`--pr`: type-aware and cross-file rules need the whole tree. A red `hk check`
fails the job but does not skip the remaining phases, so lint and the rest still
report in the same run; a failed install does stop them.

Findings show in the job log, and the first 50 KB of hk's output is appended to
the job summary. The SARIF file is kept as an `hk-sarif-<n>` artifact (one day;
`<n>` tells two calls of `pr-checks.yml` in one workflow apart), even when
`hk check` failed. This workflow does not upload it to code scanning:
that needs `security-events: write`, and GitHub checks a called workflow's
permissions when the run starts, so every caller would have to grant it, hk on
or off. A repo that wants code scanning downloads the artifact in its own
workflow and runs `github/codeql-action/upload-sarif` there.

### One job or three

`pr-checks.yml` splits light work from heavy by default. `single-job: true`
collapses it onto the heavy runner.

Use it for Gradle. Three jobs mean three configuration phases and no shared
daemon. One job keeps one checkout and one warm `GRADLE_USER_HOME`. The split
stays the right default for a cheap, independent lint.

`env` (newline `KEY=VALUE`) reaches every command step, which is where build
tuning like `GRADLE_OPTS` belongs. `build-env` applies to the build step
alone, and is parsed exactly like `env`: blank lines and `# comment` lines are
skipped, and the first `=` splits the name from the value.

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

Either shape runs behind ONE `pick` job, not two. It resolves both the light and
the heavy runner (skipping whichever `single-job` does not need), so picking
twice costs one job instead of two. It needs no checkout: it reads the changed
files through the API. `pick` and the closing `PR Checks` summary run no caller
code, so in a private repo they run on the control pool and bill no GitHub-hosted
minutes (a public repo or fork PR keeps `ubuntu-latest`). `PR Checks` also writes
a "Where it ran" table of every job's runner and queue time to its summary.

### Coverage

`coverage` picks how a coverage comment is made. It is `none` by default, which
posts nothing and adds no job. Otherwise a small `coverage` job on the light pool
posts the comment from the report your tests write, after they pass. It runs none
of your code. `AGENTS.md` has the reasoning.

| `coverage` | Your test command must write | `coverage-path` | Comment from |
|---|---|---|---|
| `none` | nothing | ignored | none |
| `vitest` | `coverage/coverage-summary.json` and `coverage/coverage-final.json` (reporters `json-summary` and `json`) | ignored | `vitest-coverage-report-action`. Thresholds come from your vitest config |
| `kover` | a Kover XML report | required, for example `app/build/reports/kover/reportDebug.xml` | `kover-report` |
| `lcov` | an LCOV file | optional, default `coverage/lcov.info` | `actions/lcov-report` |

`coverage-min-overall` and `coverage-min-changed` are percentages that fail the
`coverage` job, and so `pr-checks`, when a figure is below them. `0`, the
default, means no floor. `vitest` takes its floors from the vitest config
instead. With `kover`, only `coverage-min-overall` fails the job;
`coverage-min-changed` is marked in the comment but not enforced, because
`kover-report` cannot tell "no changed file in the report" from 0%.

`lcov` takes anything that emits LCOV. Overall coverage is lines hit over lines
found across the whole file. Changed-file coverage covers only the files the
pull request touches that the report lists, so docs and config do not count as
0%. The comment shows both figures and the lowest changed files.

```yaml
# bun
with:
  stack: bun
  test: bun test --coverage --coverage-reporter=lcov
  coverage: lcov
  coverage-min-overall: 70

# Rust
with:
  stack: rust
  test: cargo llvm-cov --lcov --output-path lcov.info
  coverage: lcov
  coverage-path: lcov.info
```

### When `build` starts

In the split shape `build` starts right after `pick`, beside `checks` and
`test`, so a push waits for the slowest of the three and not for two in a row.
That takes about a minute off every PR, and a heavy job queues on its own pool
instead of spilling onto light runners. The cost is one build spent on a push
that then fails lint. The `pr-checks` summary needs `checks`, so a failed lint
fails the required context all the same. `single-job` is unaffected.

### Timings in the job summary

`checks`, `test`, `build` and `all` run their commands through
`actions/run-phases`. Each job's summary lists every phase that has a command,
in order (`install`, `lint`, `design-lint`, `typecheck`, `test`, `build`, `smoke`), with
its result, its seconds and its peak memory:

| phase | result | seconds | peak memory |
|---|---|---|---|
| install | passed | 14 | 410 MiB |
| lint | passed | 9 | 530 MiB |
| typecheck | failed (exit 2) | 21 | 1.8 GiB |
| test | not run | - | - |

Each phase is a collapsed log group. The first failure stops the run, and the
phases after it are listed as `not run`. A phase with no command is left out.

The peak memory is what tells you whether a test or build really needs a heavy
runner, or only asks for one. `run-phases` also returns the largest of the
phases as the `peak-rss` output, in whole MiB: the largest plain figure, so an
upper bound (below) never counts. For each phase it takes the first of these
that applies:

1. **The job's cgroup v2 `memory.peak`, when it rose during the phase.** The new
   value is that phase's peak. It counts every process in the cgroup, page cache
   included.
2. **`/usr/bin/time`** (GNU `-f %M`, or BSD/macOS `-l` on a self-hosted Mac),
   when the peak did not rise or there is no cgroup. That is the peak resident
   set of the largest single process, **not the sum** of a phase's processes, so
   a build that forks many workers reads low.
3. **An upper bound** when there is a cgroup but no `time`: `<= 530 MiB`, the
   cgroup's peak from before the phase. The phase used at most that much.
4. **`-`** without either, and `peak-rss` is empty. Nothing fails.

`memory.peak` cannot be reset per phase before Linux 6.12, so in a long-lived
runner container it is an old maximum and many phases do not raise it. We do not
reset it even where we could, because the write changes what other readers of
that cgroup see. A footnote under the table says where the figures come from.

Measuring never changes a phase's exit code, and nothing it reports reaches the
phase's output or `log-dir` file.

### Docs-only changes, and the one context to require

`pick` also decides whether the change is docs-only: every file the PR touches
must match one of `docs-only-paths` (newline-separated globs, default `**.md`
and `docs/**`), read from the pull request's file list through the API. When it is, `checks`, `test`, `build` and
`all` all skip -- but `commitlint` and `zavet` still run, because they check the commit
message and the knowledge layer, not the files. The default catches a Markdown-only change; widen it
per caller for e.g. `docs/** design/**`.

```yaml
with:
  stack: bun
  docs-only-paths: |
    **.md
    design/**
```

A skip is only ever a positive finding. On `workflow_dispatch`, or whenever the
file list cannot be read in full (an API error, or a pull request of 3000 files
or more, where the API stops listing), `docs_only` is `false` and every job runs
as normal.

`pr-checks.yml` grants `contents: read` at the workflow level, so a job that
needs more asks for it: `pick` and `commitlint` read pull requests, `zavet` and
`react-doctor` write them for their comments, and only the `coverage` job
writes them for the coverage comment, so `test` and `all` run your tests with no
write token. A checkout in these workflows never keeps the job
token in its git config, so a caller's install, test and build scripts cannot
read it. Only `zavet` and `react-doctor` clone full history.

This is also why a caller should **not** add `paths-ignore: ['**.md']` to its
own `on: pull_request:` trigger to get the same effect. `paths-ignore` skips
the entire workflow, which means the workflow never runs and creates **no**
status-check context at all -- and a branch ruleset that requires one then
waits on that pull request forever, because a check that was never created can
never turn green. `docs-only-paths` gets the same skip without losing the
context.

That context is `pr-checks`, a summary job that runs unconditionally
(`if: always()`) after everything else, whether or not anything was skipped.
It fails if `checks`, `test`, `build`, `all` or `commitlint` failed or was
cancelled, and passes -- printing "docs-only change, checks skipped" -- when
they were only skipped. It is the one job a branch ruleset should require:
`<caller job id> / pr-checks` exists on every push in both single-job and
split mode, where `checks / checks` and `checks / all` do not -- exactly one
of those two is always skipped depending on `single-job`, so neither can be
named in a ruleset that has to work for every caller.

### One workflow instead of three

A repo that calls `pr-checks.yml`, `zavet-check.yml` and `react-doctor.yml`
starts three workflow runs per push, and each of the last two starts its own
runner picker job. `pr-checks.yml` already has one `pick` job, so `zavet` and
`react-doctor` can be opt-in jobs beside `checks`, on the light pool. That saves
two job starts per push, per repo that used both. `commitlint` runs on the light
pool too, so a repo with it enabled saves a third.

```yaml
jobs:
  checks:
    uses: dodi-smart/.github/.github/workflows/pr-checks.yml@v1
    with:
      stack: bun
      zavet: true
      zavet-stack: bun            # the toolchain the decision checks run on
      react-doctor: true
      # Optional: zavet-audit (report-only sweep), zavet-install (defaults to
      # install; set it when a check reads build output), react-doctor-paths
      # (defaults to **.ts, **.tsx, **.js, **.jsx and package.json).
    secrets: inherit
```

Then delete the caller's `zavet-check` and `react-doctor` jobs, and their
`paths:` filter if it existed only for React Doctor.

`zavet-dir` sets where the layer lives and `react-doctor-directory` which project to scan. The React Doctor job uses React
Doctor's defaults, so it stays advisory (`blocking: none`, `scope: changed`). A
repo that needs to tune scope, blocking or version keeps `react-doctor.yml`.

**Neither result is part of the `pr-checks` summary.** The `zavet` and
`react-doctor` jobs are separate status contexts. Turning them on does not make
`<caller job id> / pr-checks` wait for them or fail on them, so it never becomes
a required check by accident. A repo that wants zavet required names
`<caller job id> / Zavet Check` in its ruleset. React Doctor stays advisory: a
pull request touching no matching file shows a skipped job, and a required
context that is never created would wait forever.

`commitlint` runs the commitlint CLI (`actions/commitlint`, pinned by lockfile)
on the light runner. It reads the pull request's commit messages through the
API and checks out only the config file. With no config it lints against the org
preset, `@dodi-smart/commitlint-config`: config-conventional with the body and
footer line limits as warnings at 180 and the header limit an error at 180
(agent-written commits carry long `Why:` lines and session URLs). A repo that has
its own rules extends the preset by name and adds only what is its own:

```json
{ "extends": ["@dodi-smart/commitlint-config"], "rules": { "scope-empty": [2, "never"] } }
```

The config is read at the pull request's base commit, so a pull request cannot
change the rules it is linted by: a config change takes effect once it merges.
A JSON config's `extends` may name only a package in the pinned set,
`actions/commitlint/package.json`. Anything else, a relative path included, fails
the run with the allowed list, because nothing is installed on a config's say-so.
A config in another format
(a `.js` file, say) is not checked, and an import outside the pinned set fails to
resolve. To allow another package, add it to that `package.json`. The installed
tree is cached on the lockfile. The preset is not published, so its name resolves
in this action only: a local commit-msg hook cannot load a config that extends it.

### setup-stack inputs and outputs

Inputs beyond `stack` and the command overrides:

| Input | Default | Meaning |
|---|---|---|
| `env` | empty | Newline `KEY=VALUE` for every command step. Written to the file named by the `env-file` output, because `$GITHUB_ENV` refuses `NODE_OPTIONS`. |
| `build-env` | empty | The same format and the same parser, for the build command only. Written to the `build-env-file` output. |
| `bun-version` | `auto` | See below. |
| `rust-toolchain` | `stable` | Passed to the pinned rust toolchain action: `stable`, `nightly`, `1.89.0`, or any rustup specifier. |
| `next-cache` | `auto` | Keep Next.js's `.next/cache` between jobs: `auto`, `true` or `false`. See Caches. |

Outputs: `env-file` and `build-env-file` (both always written, empty when
nothing was given, so source them unconditionally), plus the resolved `install`,
`lint`, `typecheck`, `test`, `build` and `design-lint` commands. `cache-enabled`
is `true` when the job uses the GitHub Actions cache (hosted, or self-hosted
macOS without `RUNNER_PERSISTENT_CACHE`) and `false` when isolated, on
self-hosted Linux, or with a runner cache directory.

```sh
. "$ENV_FILE"          # every command step
. "$BUILD_ENV_FILE"    # the build step only
```

**Bun follows the repo.** `bun-version: auto` (or empty) installs the version the
repo pins, so CI runs what developers run and a frozen install does not fail on a
lockfile format the newest bun changed. It checks, from the checkout root and in
this order: `package.json` `packageManager` (`bun@x.y.z`, any `+sha` suffix
dropped), `.bun-version`, `.tool-versions` (`bun x.y.z`), `mise.toml` and
`.mise.toml` (`bun = "x.y.z"` under `[tools]`). The step log says what it chose
and from where. When none names bun it installs `latest` and prints a notice.
Any explicit version, `latest` included, is used as given. The repo must be
checked out before `setup-stack` runs.

**Rust is pinned.** The toolchain action is pinned to a commit of its `master`
branch (it publishes no version tags), and Renovate can still move that pin.

### Caches

`setup-stack` resolves the mode from `isolate`, `cache` and the runner:

- **Verification jobs isolate.** `deps-verify` pins caches to `RUNNER_TEMP` with
  GitHub cache off, because a verification job that can see yesterday's tree is
  not verifying.
- **Self-hosted Linux uses home dirs**, so the per-runner named volumes are
  actually read. GitHub cache stays off there.
- **Self-hosted macOS caches like hosted.** Those runners are image-based VMs
  that start every job with an empty home, so `cache: auto` is true there and
  nothing else would persist.
- **Only the default branch writes the Actions cache.** An entry saved on a
  pull request ref is scoped to that PR and no other PR can read it, and on the
  Mac hosts the transfer is slow (a 473 MB entry took minutes to save and 157 s
  to restore). So `setup-gradle`, `rust-cache` and the Kotlin/Native cache save
  from the default branch only and every other ref restores. A repo whose checks
  run only on `pull_request` never saves an entry: to keep the cache warm, run
  the job on the default branch too (a push or a schedule).
  `RUNNER_PERSISTENT_CACHE` below needs none of that.
- **`RUNNER_PERSISTENT_CACHE` makes a directory the cache.** When the runner
  exports that variable (its `.env` is exported into every job) as an existing
  writable directory, and the job is not isolated, `setup-stack` points
  `GRADLE_USER_HOME` at `$RUNNER_PERSISTENT_CACHE/gradle` and `KONAN_DATA_DIR`
  at `$RUNNER_PERSISTENT_CACHE/konan`, creates both, and turns every Actions
  cache off: `setup-gradle`, the Kotlin/Native cache, `rust-cache`,
  `flutter-action` and setup-bun's. The directory is the cache, as the named
  volume is on Linux. It works on any OS and is aimed at the Mac VMs. A value
  that is not a writable directory logs a warning and the usual mode applies;
  it never fails the job. The step's `persistent` output and its log line show
  which one was used.
- **`~/.pub-cache` is job-scoped in every mode.** A home dir is only worth using
  if a volume backs it, and the image mounts none for pub.
- **Hosted uses one mechanism per stack**, `setup-gradle` / `rust-cache` /
  `flutter-action`. Never a package store, and never `restore-keys` on one, which
  is how a partial tarball comes back on every retry.
- **setup-bun's cache of the bun executable follows the same mode**, so it is
  off on self-hosted Linux, where a moved work dir made it restore bun to the
  wrong path.
- **`.next/cache` is kept for Next.js apps** (`next-cache`, default `auto`):
  every directory with a `next.config.*` within three levels, for stack `bun`
  or `node` (`true` takes any stack, and the root when none is found). Where a
  directory outlives the job (`RUNNER_PERSISTENT_CACHE`, else `~/.cache` on
  self-hosted Linux), `.next/cache` becomes a link into
  `<dir>/next/<owner>-<repo>[/<app dir>]`, out of reach of checkout's clean.
  Elsewhere, when the Actions cache is on, `actions/cache` keeps it, keyed on
  the lockfiles and then the commit's tree. Always off when isolated.
- **Gradle repos with a cache on** get `setup-gradle`, including `stack: xcode`
  when the repo has a root `gradlew`. A repo whose `gradle/libs.versions.toml`
  names the multiplatform plugin and a `kotlin` version also caches `~/.konan`,
  Kotlin/Native's toolchain, keyed on OS, arch and that version alone. Both need
  the repo checked out before `setup-stack`.
- **The `~/.konan` entry is saved only on a miss**, by `actions/cache`'s post
  step after the build, never by an inline `actions/cache/save`, which would
  store an empty or partial `~/.konan`.

**Optional: a persistent cache for the Mac VMs.** On each Mac host, start the VM
with a directory share, one directory per VM:

```sh
tart run --dir=ci-cache:$HOME/ci-cache <vm>
```

Never share one directory between two VMs running at once: Gradle's and
Kotlin/Native's locks are not reliable across two guests on one share. Then set
`RUNNER_PERSISTENT_CACHE=/Volumes/My Shared Files/ci-cache` in the runner's
`.env` inside the VM image. The Gradle distribution and Kotlin/Native's
toolchain then survive the VM, which removes both the download and the Actions
cache transfer. The path contains spaces; `setup-stack` quotes it everywhere,
and a caller's shell step that reads `GRADLE_USER_HOME` or `KONAN_DATA_DIR` has
to quote it too.

**Never cache a project build directory.** Not `build/`, not `*/build`, not
`.gradle`. `*/build/intermediates` holds absolute paths and the workspace root is
not stable between runners, so AGP rejects its own inputs. A per-SHA key also
misses on every commit by construction, then falls through `restore-keys` to
whatever another branch left behind. It surfaces as a compile error in a file the
pull request never touched. Reuse of compiled output is the build tool's job, by
content hash, and `setup-stack` already wires it up.

`.next/cache` is the exception, and the only cache that takes `restore-keys`:
Next addresses its own entries by content, so an entry from another commit is
reused where it fits. `build/` and `.gradle` hold absolute paths; Next's cache
does not. The rest of `.next` is never cached.

## Supabase checks

`supabase-checks.yml` covers the Supabase-side checks a bun/node `pr-checks.yml`
run never touches: a Deno edge-function check, a generated-types check, and
pgTAP tests, plus an opt-in lint of the migrations a pull request changes. The
jobs that start Postgres run on `ubuntu-latest` only, with no runner picker —
the self-hosted fleet runs jobs inside containers on a shared daemon, so
`supabase db start` publishes postgres's ports on the HOST while the CLI polls
the CONTAINER's own localhost. `migration-lint` starts no database and only
reads files, so it runs on the light pool of a private repo and on hosted
otherwise. `concurrency`, `paths:` and the dispatch-aware draft gate stay with
you, same as `pr-checks.yml`.

| Input | Default | Meaning |
|---|---|---|
| `cli-version` | *(required)* | Supabase CLI version, pinned exact with a `renovate: datasource=npm depName=supabase` marker tracking the same `supabase` devDependency the repo installs from. Generated types must come from that same CLI or the diff below fails on formatting, not schema. |
| `types-path` | `""` | Path of the committed generated types. Empty disables the `types` job (reported skipped, not failed). |
| `migrations-paths` | `supabase/migrations`, `supabase/seed.sql` | Newline-separated paths (a directory covers what is under it) or globs whose change triggers the heavy steps of the `types` and `pgtap` jobs on a pull request (`pgtap` also on a change under `supabase/tests`). Any event that is not a pull request always runs them. |
| `seed-check` | `false` | Re-apply `supabase/seed.sql` after `db start` to prove it is re-runnable. |
| `deno-dir` | `""` | Directory of Deno-only source, e.g. `supabase/functions`. Empty disables the `deno` job. |
| `pgtap` | `false` | Run `supabase test db` in its own job. |
| `migration-lint` | `false` | Lint the migrations a pull request adds or changes with [squawk](https://squawkhq.com), in its own job. Off reports the job as skipped. |
| `migrations-path` | `supabase/migrations` | The one directory `migration-lint` lints. Not `migrations-paths` (plural): that is the list of paths whose change starts the `types` and `pgtap` jobs. Only `*.sql` files the pull request added, modified or renamed under this path are linted, so a migration already applied never fails a pull request. |
| `migration-lint-excluded-rules` | `""` | squawk rule names to skip, separated by commas or whitespace. Passed as `--exclude`, which replaces `excluded_rules` in the repo's `.squawk.toml`; every other setting in that file (`pg_version`, `assume_in_transaction`, `excluded_paths`) still applies. |
| `migration-lint-blocking` | `false` | `false` reports findings as warnings and the job stays green, so the baseline is visible first. `true` fails the job on any finding. squawk failing to install or run fails it either way. |
| `deno-version` | `v2.x` | Passed straight to `denoland/setup-deno`. |
| `timeout-minutes` | `30` | Per job. |

The `types` and `pgtap` jobs read the pull request's file list through the API
instead of cloning the history, and always report success, never skipped, when
nothing relevant changed. Reading it needs `pull-requests: read` on the token; a
caller that narrows `permissions:` must keep it, and without it the jobs run
everything rather than skip. The local stack's Docker images are cached between
runs under an exact key: CLI version, runner OS and architecture, and a hash of
`supabase/config.toml` and any `supabase/.temp/*-version`. A pull request's first
run pulls them, since a cache saved on a pull request is visible to that pull
request alone. Run these checks on pushes to the default branch as well, and every
pull request reads what those runs saved.

`migration-lint` reads the same file list, installs one pinned squawk binary
(checked against the release's sha256 digest) into the runner's temp directory,
and lints the changed migrations only. Findings are annotations on the file and
line, plus a table in the job summary. Turn `migration-lint-blocking` on once the
baseline is clean. On any event but a pull request there is no diff, so it
reports success without linting. When the file list cannot be read in full
(an API error, or the 3000-file cap) it lints every `*.sql` under the path rather
than none. It adds no permission: it needs the `pull-requests: read` the other
jobs already use.

```yaml
jobs:
  supabase:
    if: github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == false
    uses: dodi-smart/.github/.github/workflows/supabase-checks.yml@v1
    with:
      # renovate: datasource=npm depName=supabase
      cli-version: 2.116.0
      types-path: src/lib/supabase/database.types.ts
      seed-check: true
      deno-dir: supabase/functions
      pgtap: true
      # Opt in advisory first; add `migration-lint-blocking: true` once clean.
      migration-lint: true
      migration-lint-excluded-rules: require-concurrent-index-creation
```

## Runners

`pick-runner.yml` takes a semantic `weight` and resolves it to a `runs-on`
selector. It is a thin wrapper around `actions/pick-runner`, the composite action
that does the actual selecting; call the action directly from inside a job you
already have (as `pr-checks.yml`'s `pick` job does, twice, and as every agent
workflow's `gate` job does, once, after `agent-gate` decides the run should
proceed) rather than adding a job just to reuse the workflow.

The picker is **static**. It makes no API call, mints no token and lists no
fleet. It maps a weight to fixed capability labels, so it costs a few
milliseconds and cannot fail on a rate limit or a missing secret.

| `weight` | Selector | Use |
|---|---|---|
| `light` | `self-hosted,Linux,light` | lint, typecheck, checks, releases, reading a diff |
| `heavy` | `self-hosted,Linux,large` | builds, Docker, full suites |
| `agent` | `self-hosted,Linux,agent` | agent workflows: review, triage, assist |
| `apple` | `self-hosted,macOS,ARM64` | Apple toolchain, signing |
| `hosted` | none | forces `hosted-runner`, `ubuntu-latest` by default |

Selectors name capability labels, never an architecture and never a machine name.
A runner of any arch that joins a pool is picked up with no change here, and a
machine name would not survive re-registration.

`light` and `heavy` are tiers of intent, so ask for the one that describes your
work. They stay apart even when one pool could serve both, because re-tiering is
then two lines here instead of an audit of every caller.

### Overflow happens in GitHub's queue

There is no fallback and no `fell-back` logic. The large runners also carry the
`light` label, so a light job waits for whichever light-capable runner frees up
first, and a busy light pool overflows onto the large one by itself. `heavy`
selects `large` only, which no light-only runner carries, so a heavy build can
never land on a small host (exit 137). `fell-back` is always `false`.

`fallback` and `fallback-when` are deprecated: they change nothing, and a caller
that still passes either gets a warning naming it. They are removed once no
caller passes them. The `gh-app-client-id` and `gh-app-private-key` inputs, and
the two `GH_APP_*` secrets of `pick-runner.yml`, are accepted and ignored.

### No run-time switch

Nothing repoints a weight at run time: no org or repository variable, no input.
A pool's labels change in `pick.sh`, in a release that goes through `next` like
any other. Keeping the self-hosted pools up is the job of their capacity and of
the runner monitoring, not of an escape to hosted runners.

Static `runs-on:` expression used by helper jobs that run no caller code:

```yaml
runs-on: ${{ fromJSON((github.event.repository.private && !github.event.pull_request.head.repo.fork) && '["self-hosted","Linux","light"]' || '"ubuntu-latest"') }}
```

`pr-checks.yml`'s `pick` and `PR Checks` use it with `"control"` in place of `"light"`; see AGENTS.md.

Public repos and fork pull requests **always** get hosted runners, with no way to
opt out. The runner group refuses public repos, and a fork PR would otherwise run
attacker-authored code on our own hardware against a cache the next job inherits.
That holds for the action and for the expression above, and `labels` cannot
change it.

The tools on a self-hosted image are bash, git, gh, jq, curl and Node. A helper
job that moves to `light` must not need anything else; `changed-files` also needs
`python3`, and `pr-checks.yml`'s `pick` warns if it is missing.

## Models

Every agent run names a `stage`, and `actions/pick-model` picks the model and
the turn cap from it, the issue's fields and what the gate already found. No
workflow names a model id, and self-test fails one that does. The first row
that matches wins.

| Stage | Opus when | Otherwise | Turn cap |
|---|---|---|---|
| triage, assist | always | | action default |
| implement | Effort High, Risk High or Critical, Priority Urgent, or Risk or Effort unset | Sonnet | action default |
| fix-ci | round 2 or later, Risk High or Critical, Effort High, Priority Urgent | Haiku on round 1 when only `hk check --all` failed, else Sonnet | 30 Haiku, 60 else |
| fix-review | always | | 60 |
| review | full review, sensitive paths or a `sec:` label | Sonnet for a review scoped to trailered commits | action default |
| deps-verify | CI red, or a major update | Haiku for a green patch or lockfile update, Sonnet for a green minor | 80 red, 40 major or Sonnet, 30 Haiku |
| fleet-sync | never | Sonnet | 40 |

Haiku runs only where a deterministic step already knows the answer and the
next step catches a miss: the automerge gate after deps-verify, and an Opus
round 2 after a lint fix that did not turn CI green. A full review stays on
Opus even at Risk Low, because on the merge tier it is the last check before
an unattended merge.

Each run writes one `Agent run` notice with the stage, model, rule, turns and
cost, so the models can be compared from the annotations. To move every run
off a model at once, set the org variable `AGENT_MODEL_PIN` to a model id.
Every shared workflow forwards it to run-agent, and it wins over the policy
and over a caller's `model` input. A workflow that calls run-agent directly
forwards `model-pin: ${{ vars.AGENT_MODEL_PIN }}` itself. Unset it to go back to
the policy.

### Org additions to agent runs

Four org settings reach every agent run that a shared workflow starts, so a
tool the org uses in its agents is switched on once, not per repo.

| Setting | Kind | What it does |
|---|---|---|
| `AGENT_PLUGINS` | variable | Plugins added to the workflow's own, newline-separated |
| `AGENT_PLUGIN_MARKETPLACES` | variable | Marketplaces for those plugins |
| `AGENT_ENV` | variable | `KEY=VALUE` lines set for the agent |
| `AGENT_ENV_SECRET` | secret | The same, with the values masked. Its line wins when both name a key |

The env reaches the agent and its hooks through claude-code-action's settings,
and never `GITHUB_ENV`, so the steps that publish after the agent do not see
it. run-agent refuses a key that would change the runner, the action or the
agent's credentials (`GITHUB_*`, `RUNNER_*`, `ANTHROPIC_*`, `CLAUDE_CODE_*`,
`PATH`, `HOME`, `GH_TOKEN`, `GIT_*`, `LD_*` and similar) and fails the step,
because a wrong key would be ignored without anyone noticing. The settings file
is deleted after the run. A workflow that calls run-agent directly forwards the
four itself, as `org-plugins`, `org-plugin-marketplaces`, `agent-env` and
`agent-env-secret`.

## Versioning

Pin `@v1`. It is a moving tag, but it no longer moves on a merge: it moves when
a release is promoted (see [Releasing and channels](#releasing-and-channels)).
A breaking input change cuts `v2` rather than redefining `v1`.

Releases are cut by semantic-release from `main`, so the version comes from the
commit messages. `feat:` opens a minor, `fix:` a patch, and a breaking change
footer a major.

The major tag is derived from the version, so this works unchanged at `v2` and
beyond. Promoting `2.0.0` creates `v2` and **stops touching `v1`**, which freezes
at the last `1.x`. Callers pinned to `@v1` keep the old major until they choose
to move, which is the whole point of pinning a major.

One consequence to know before you cut a `v2`: `main` is the only release branch,
so once `2.0.0` ships there is no way to release a `1.x` patch. That needs a
maintenance branch added to `release.config.mjs`, for example
`branches: ["main", "1.x"]`, and it is easier to add before you need it than
during an incident.

`chore(deps)` also cuts a patch, which is specific to this repo. Renovate labels
every dependency update `chore(deps)`, and elsewhere that deliberately releases
nothing. Here the dependencies are the action versions these workflows run on, so
a bump that never reached a release would leave every caller on the old ones. A
plain `chore:` with no `deps` scope still releases nothing.

Do not pin `@main` even so. `@v1` still moves only when a release is promoted, so
a commit that releases nothing, a `docs:` or a `ci:` change, never reaches a
caller. `@main` picks up every commit. `@v1` is also a version you can name in a
rollback, and `@main` is not.

### Releasing and channels

A merge to `main` is no longer a rollout to everyone. A release moves through two
channels:

| Channel | Moved by | Who follows it |
|---|---|---|
| `next` | every release, right after `Self test` passes on the merge commit | a small set of canary repositories, which pin `@next` |
| `v1` | the `Promote` workflow, on purpose | every other caller, which pins `@v1` |

1. **Merge.** semantic-release cuts `vX.Y.Z` on `main`. `scripts/channel-tag.sh`
   then builds a child commit of that tag, which is not on `main`, where every
   `dodi-smart/.github/actions/*@v1` and `dodi-smart/.github/.github/workflows/*@v1`
   reference in `.github/workflows/*.yml` and `actions/**/action.yml` is rewritten
   to `@pinned/vX.Y.Z`, the tag of that same commit. That commit is tagged
   `pinned/vX.Y.Z` and `next` is force-moved onto it. Without the rewrite a caller
   on `@next` would run the new workflow but each action from whatever `v1` is at
   that moment. Pinning to `@vX.Y.Z` would not be enough either: that tag is the
   release commit, whose own references still say `@v1`, so an action called by
   a pinned action would run `v1`. Pointing every reference at the pinned commit's
   own tag makes `@next` one commit at every depth. Third-party references
   (`actions/checkout@v7`) and exact versions are never touched.
2. **Soak.** The canary repositories run the release on their own pull requests.
   Nobody else sees it.
3. **Promote.** Run the `Promote` workflow, which force-moves `v<major>` onto
   `pinned/vX.Y.Z`:

   ```bash
   gh workflow run promote.yml -R dodi-smart/.github                 # what next points at
   gh workflow run promote.yml -R dodi-smart/.github -f version=1.20.0
   ```

   The major is taken from the version, so promoting `2.0.0` moves `v2` and leaves
   `v1` alone. `next` stays one channel and always follows the newest release.
4. **Roll back.** Promote an older version: `-f version=1.19.2`. A version cut
   before channels existed has no pinned commit, so its own tag is used, and it
   behaves as it always did. To roll the canary back, move `next` by hand:
   `scripts/channel-tag.sh pin --version 1.19.2 --force`.

**Automatic promotion is off.** Set the repository variable `AUTO_PROMOTE` to
`true` and the hourly `Promote` schedule promotes `next` once it has been in
place for 24 hours (`AUTO_PROMOTE_MIN_AGE_HOURS` changes that). It never promotes
an older version over a newer one, and it does not look at how the canary runs
went, so turn it off or promote by hand when one is red.

**The first release after this was introduced moves only `next`.** `v1` stays on
the last release cut before channels, and every caller on `@v1` keeps working
exactly as it did. Until `Promote` is run, `v1` does not move at all, so nothing
merged since reaches a caller on `@v1`. The canary callers only start following
`next` when they change `@v1` to `@next`, which is a change in each of those
repositories and not in this one.

One thing pinning does not buy you here. `claude-code-action` refuses to run when
the workflow file differs from the default-branch copy, which is a correct
control, since a pull request could otherwise edit the reviewer to exfiltrate its
token. It means a change to an agent workflow cannot be exercised on the pull
request that makes it, only after merging.

## Shared semantic-release config

`semantic-release/` is an npm workspace in this repo that holds the org's
shared semantic-release configuration, `@dodi-smart/semantic-release-config`.
It carries the release rules, the changelog sections and the plugin suite,
pinned to versions that agree with each other, so a consuming repo does not
have to work that out on its own.

The package is never published to any registry. It reaches a consumer through
`actions/semantic-release-config`, which copies this checkout's root
manifests, lockfile and `semantic-release/` into a private prefix, installs
the plugin dependencies there, then links that prefix's `semantic-release`
directory into the consumer's `node_modules` by name. The checkout the
action was fetched with is left untouched, so nothing sharing it loses a
dependency. The shared `release.yml` runs that action automatically before
semantic-release, gated by its `shared-config` input (default `true`); a
caller whose `release-command` does not run semantic-release sets it `false`
to skip the install. A repo that hand-rolls its own release job adds one
step, after its own install and before semantic-release:

```yaml
- uses: dodi-smart/.github/actions/semantic-release-config@v1
```

`actions/semantic-release-config/test.sh` checks this the way `Self test`
runs it for the other actions: by resolving the linked package and its
plugins from a scratch consumer, not by reading the installer's output.

There are two ways to use the config once it is linked. Extend it whole, for
a single-package repo released from `main` with `develop` as a prerelease
channel:

```json
// .releaserc.json
{ "extends": "@dodi-smart/semantic-release-config" }
```

Or compose, when the repo needs its own plugin list, for example a version
file to rewrite. No `extends` line: import the helpers you want and list
them.

```js
// release.config.mjs
import { branches, commitAnalyzer, releaseNotes, changelog, git, github } from "@dodi-smart/semantic-release-config";
export default {
  branches,
  plugins: [commitAnalyzer(), releaseNotes(), changelog, git({ assets: ["pubspec.yaml", "CHANGELOG.md"] }), github()],
};
```

A consumer installs `semantic-release` and nothing else. Every plugin the
config names is a dependency of the package itself, and the package arrives
by the link, not by an install, so nothing is added to the consumer's
`package.json` or its lockfile.

Updates arrive the way workflow updates do: someone merges a change here, the
release is promoted to `@v1`, and every consumer is on the new config the next time it
releases. There is no per-repo version to bump, and so no way for a consumer
to lag.

Watch for `effect`, not `hidden`. Changelog section entries used to hide a type
with a boolean `hidden` property; the preset that renders them now reads
`effect: "bump" | "hidden"` instead and does not warn on the old key, so a type
still carrying `hidden: true` renders anyway and leaks into the notes as an
untitled bullet. Compose your own `types` list with `effect`.

`commitAnalyzer({ releaseRules })` replaces a shared rule of the same type and
scope rather than adding beside it, because the analyzer treats a
`release: false` match as undecided and lets a later matching rule win; a
shared rule could otherwise never be turned off. `npm` is always in the
default config, since that config is for a Node package; a repo that is not
one, even with an incidental `package.json`, composes and leaves `npm` out.
`exec` is a plugin path with no options of its own; pass your own `*Cmd`
entries as `[exec, { successCmd: "..." }]`. `github()` takes
`{ releasedLabels }`; pass `github({ releasedLabels: false })` in a repo
without `release:prod` / `release:staging` labels.

Two plugins in `semantic-release/package.json` are pinned to exact beta
versions, because their stable releases cannot render this package's v10
changelog preset. Renovate in this repo offers the matching stable release
automatically once one exists, because the pin is exact rather than a caret
over a prerelease. When it lands, the pins here move to stable and every
consumer picks it up on its next release, the same way any other change here
reaches them.

Every plugin this package exports is an absolute path, resolved from inside
this package, not a bare package name. That is what makes the composed form
work with no `extends`. semantic-release resolves a plugin named in a config
from its own directory first, so a bare name would get whatever copy
semantic-release itself depends on; the `extends` redirect only fixes that
for plugins the extended config lists, and `--extends <file>` on the command
line, the reusable release workflow's `modules` path, replaces the config's
own `extends` entirely. A path sidesteps all three. Both usage modes are
covered by real dry runs in the package's end-to-end test, run through the
installer.

## Review verdict

Every `pr-review.yml` run ends in a verdict that a workflow can read, besides
the comment a person reads. This is a contract: other workflows merge on it.

- **Commit status `review / verdict`** on the head commit the review read.
  `success` means approve. `failure` means changes, with the number of
  blocking findings in the description. No status means not reviewed, which
  every consumer treats as not approved. A push moves the head, so a new
  commit is unreviewed until reviewed again.
- **Artifact `review-verdict`** holding `review-verdict.json`:

  ```json
  {"verdict": "approve", "blocking": [], "sha": "<head sha>", "mode": "full"}
  ```

  `blocking` lists `{"path", "line", "summary"}` entries, the findings the
  reviewer would not merge with. `mode` is `full` for a whole pull request and
  `scoped` for a bot's trailered commits.

The job writes both from the agent's file and fails closed: a missing or
malformed file, an unknown verdict, or `approve` with a blocking finding all
become `changes`. The status is posted with the org App's token, because asking
for `statuses: write` in the workflow would break every caller that does not
grant it. The App needs the Commit statuses permission (read and write). Without
it the run warns and posts no status.

A bot's pull request is reviewed only when a bot applied `agent:review`, which
is what `actions/request-review` does with the org App token when the head has
no verdict yet. When the PR's commits carry a `scope-trailers` trailer
(`Deps-Verify-Round` by default), only those commits are reviewed, on sonnet
from their diff: the automation's own changes on top of another bot's work.
deps-verify requests one for every `deps:fixed` PR. No caller change is needed:
the caller's `labeled` trigger already covers it.

## Renovate

```json5
{ extends: ["github>dodi-smart/.github"] }
```

`default.json` carries only what is true of every repo. Ecosystem rules stay in
the repo that has that ecosystem, because a rule matching nothing is worse than
no rule: it reads as coverage.

The filename matters. For a bare `github>owner/repo`, Renovate fetches
`default.json` and no other name, then falls back to `renovate.json` -- which
extends this preset, so resolution goes circular and every repo silently drops
to stock defaults. Renovate parses a `.json` preset as JSONC, so it keeps its
comments.

Updates arrive weekly, before 6am on Monday. Branches outside that window are
left alone (`updateNotScheduled: false`) and rebased only on a conflict
(`rebaseWhen: conflicted`), so a repo's CI is not rerun all week by Renovate.
At most eight PRs are open at once; security PRs ignore the schedule and the
limit. Non-major Action bumps wait three days after release
before a PR opens, then automerge.

### Dependency verification

`deps-verify.yml` gets the build verdict from the repo's own `pr-checks` run on
the PR's head commit, and builds nothing itself when that run exists. It then
hands the verdict and the failed jobs' logs to an agent. The agent reads the
release notes, looks for breaking or deprecated APIs this repo actually calls,
and fixes them when it can. The job posts one comment, rewritten on every run,
and sets exactly one label:

| Label | Means |
|---|---|
| `deps:verified` | CI green, nothing breaking reaches this repo |
| `deps:fixed` | Green after a fix commit on the branch. Read the fix before merging |
| `deps:needs-manual` | Still red, or a fix needs something the job may not do |

Why it reads CI instead of building:

- **A second build ran out of memory.** Building here as well ran a second full
  build of the same commit next to `pr-checks`, on the same runner hosts. The
  pair ran out of memory, and both reported a fine update as red.
- **One failure on the runner gets a retry.** A `pr-checks` run that failed on
  the runner (exit 137, a killed Gradle daemon, a lost runner, a full disk) is
  re-run once, failed jobs only. A second failure like that is reported as
  `red:infra`.
- **Only a repo with no `pr-checks` builds here.** When none of the repo's
  workflows calls `ci-workflow`, or it is set to `""`, the job builds the PR
  itself, isolated. That is read from the workflow files, not guessed from a
  timer.

The rules on fixes:

- A fix is code, plus the companion versions the update needs: the Gradle
  wrapper a new AGP requires, a peer dependency, the Kotlin that pairs with a
  Compose compiler. Only in the stack's version files (`setup-stack`'s
  `version-files`), each recorded and carried as a `Deps-Verify-Bump:`
  trailer. A version this update set is never changed.
- Lockfiles are never edited by hand. The stack's `lock` command regenerates
  the one next to a changed declaration, and the result goes into the round.
- For a major, the agent reads the migration guide between the two versions,
  runs a codemod when the guide names one, and runs typecheck and test after
  changing code. Majors are never merged by automation.
- At most two fix rounds per PR. After that the job reports and stops.
- The job pushes, never the agent, through `actions/push-round`. It checks
  every commit's author and files first, and pushes with the org App's token,
  so the checks run on the new commit.
- The commits carry the author the preset lists under `gitIgnoredAuthors`, so
  Renovate still owns the branch. If Renovate rebases and drops the fix, the next
  run makes it again.
- A fix is pushed only where Renovate ignores that author: the repo's Renovate
  config extends this preset, or lists the author in its own
  `gitIgnoredAuthors`. Anywhere else the agent commits nothing and the PR ends
  `needs-manual`, with the comment naming the file to change. A repo with no
  Renovate config is not held back.
- The push starts PR Checks on the fix, whose completion re-verifies the PR.
  That run's actor is the App that pushed, and the agent accepts it only when
  the head commit is a fix round of this job.

A red build is `needs-manual` even when the agent finds the cause was already on
the base branch. The comment says so in one line.

Every run that reaches the agent ends with a verdict that says why: when the agent leaves no report, `actions/run-agent` writes `needs-manual` with the cause. A PR merged or closed while the job queued gets nothing published.

Which runner it takes:

- **Nothing waits for `pr-checks`.** The caller triggers on `pull_request` and
  on `workflow_run` for its PR Checks workflow. The short `gate` (light pool in a
  private repo, hosted in a public one) reads the
  `pr-checks` run on the head commit once. While it has not finished, the run
  stops there, and the run's completion starts verification again with the
  verdict ready. A runner failure is re-run the same way, once. No job holds a
  runner while CI runs; AGENTS.md has why.
- **A green build reads on a light runner.** The `verify` job runs on the light
  pool when the verdict is green, so a green PR never holds a heavy slot. It
  takes the heavy pool only to build or fix: a red or infra verdict, or a repo
  with no `pr-checks` that builds here. With an `apple` or `hosted`
  `runner-weight`, or explicit `runner-labels`, there is no lighter pool, so
  `verify` uses that selector either way.
- **A rebase of an unchanged update runs nothing.** The gate hashes the changed lines
  of every file except lockfiles and records the hash in the comment. When the
  build is green, the PR already carries `deps:verified` (or `deps:fixed` with its
  fix commits still on the branch) and the hash is the same, `verify` does not
  start, and the label and comment stay. A changed diff, a missing record, or any
  red build goes to the agent, as does a repo that builds here, since there is no
  verdict to trust yet.
- **Lock file maintenance is judged by the build.** A green build with only
  lockfiles changed gets `deps:verified` and a one-line comment, with no agent.
  A red one goes to the agent as before.

The caller listens for both events. `workflows:` names the caller's own PR
Checks workflow by its `name:`. Without the `workflow_run` trigger nothing starts
verification once `pr-checks` finishes:

```yaml
name: Dependency Verification
on:
  pull_request:
    # `labeled` is the safe manual re-run: apply `agent:review` to a Renovate PR.
    types: [opened, synchronize, reopened, labeled]
  # `branches:` keeps a human PR's checks from creating a run at all.
  workflow_run:
    workflows: [PR Checks]
    types: [completed]
    branches: ['renovate/**', 'dependabot/**']
jobs:
  verify:
    # Cheap pre-filter, so a human PR never starts a hosted job. The shared
    # workflow gates again on the resolved pull request.
    if: >-
      (github.event_name == 'pull_request'
        && contains(fromJson('["renovate[bot]","app/renovate","dependabot[bot]"]'), github.event.pull_request.user.login)
        && (github.event.action != 'labeled' || github.event.label.name == 'agent:review'))
      || (github.event_name == 'workflow_run'
        && github.event.workflow_run.event == 'pull_request'
        && !contains(fromJson('["cancelled","skipped"]'), github.event.workflow_run.conclusion))
    uses: dodi-smart/.github/.github/workflows/deps-verify.yml@v1
    secrets: inherit
    permissions:
      contents: read
      pull-requests: write
      actions: write
      id-token: write
    with:
      stack: bun
```

`env` and `build-env` mean what they mean in `pr-checks`: same format, same
parser, and `build-env` reaches the build command only. They matter when the
agent reproduces a failure to fix it, and when the job builds on its own. Copy
the caller's `pr-checks` block across:

```yaml
    with:
      stack: bun
      env: |
        NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
      build-env: |
        NODE_OPTIONS=--max-old-space-size=4096
```

Commands run one per subshell, so `install: cd app && bun install` does not
leave the next step inside `app/`.

### Dependency automerge

`deps-automerge.yml` merges a dependency PR when the evidence is complete. It
runs no agent. Each run decides once through `actions/merge-gate`, the one
place any unattended merge in the org is decided; its rules and their order are
in `actions/merge-gate/gate.sh`. In short: a dependency bot's minor, patch or
lock file update (`deps-intent`'s `kind`), `deps:verified` or `deps:fixed` with
an approving `review / verdict`, the required check green on the head, only
allowed commit authors, no `agent:no-touch`, and `DEPS_AUTOMERGE` not `false`.
Majors never merge. The merge uses the org App's token, `--rebase`, pinned to
the head it read. Minor and patch updates also wait three days after release,
from the preset's `minimumReleaseAge`: the gate holds a PR while Renovate's
`renovate/stability-days` status is pending, because no branch rule requires
that status and GitHub would merge past it. A PR that conflicts with its base
does not merge either; the gate ticks Renovate's rebase box with the App token,
and the rebased head goes through deps-verify again.

The caller listens for every event that can complete the evidence:

```yaml
name: Dependency Automerge
on:
  # deps-verify set deps:verified or deps:fixed (with the App, so it fires).
  pull_request:
    types: [labeled]
  # pr-review posted review / verdict on a deps:fixed PR, or Renovate's
  # renovate/stability-days turned green.
  status:
  # The required check finished after the verdict was set.
  workflow_run:
    workflows: [PR Checks]
    types: [completed]
    branches: ['renovate/**', 'dependabot/**']
jobs:
  merge:
    uses: dodi-smart/.github/.github/workflows/deps-automerge.yml@v1
    secrets: inherit
    permissions:
      contents: read
      pull-requests: read
      checks: read
      statuses: read
```

`required-check` takes another check run name when the repo's PR Checks caller
job is not called `checks`.

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
validates the Renovate preset, and runs `hk check --all`. That runs shellcheck,
jactionlint (workflow correctness and security, config in
`.github/jactionlint.yaml`), typos and the whitespace and merge-marker checks
defined in `hk.pkl`.

### Git hooks

Lint runs as git hooks through [hk](https://hk.jdx.dev), configured in `hk.pkl`. Running `mise install` turns them on for your clone: the `postinstall` hook in `mise.toml` runs `hk install --mise`. CI skips it. The hooks include a conventional-commit check on the message.

- Run the checks by hand with `hk check --all`, or fix what can be fixed with `hk fix --all`.
- Skip the hooks for one commit with `HK=0 git commit ...`.
- The hook config is shared by every worktree of the clone. On a branch without `hk.pkl` the hooks do nothing, as long as hk is available globally: `mise use -g aqua:jdx/hk@2.4.0`. Alternatively, install once per machine with `hk install --global --mise` (Git 2.54 or later), which skips repos without hk config.

Read `AGENTS.md` before changing anything. If you add a workflow, add its rule to
the table there with the one line that says why, and extend
`actions/agent-gate/test.sh` if it introduces a new gate shape.
