# .github

Org-wide GitHub defaults for `dodi-smart`.

**This repo is an add-on to [`dodi-smart/agent-skills`](https://github.com/dodi-smart/agent-skills), not a separate project.**
Think of it as that repo's GitHub-mandated mount point. It holds only what has to
live at a fixed path:

- `.github/ISSUE_TEMPLATE/` — issue templates, inherited by every repo in the org
  that does not define its own
- `.github/workflows/` — reusable workflows called by thin callers in each repo

Everything else — the skills, the label manifest, the scripts, and all the
reasoning — lives in **[`dodi-smart/agent-skills`](https://github.com/dodi-smart/agent-skills)**.
There is one knowledge layer and it is over there; see `AGENTS.md` in this repo
for which decisions govern these workflows, and `DODI-00011` for why the split is
drawn here.

## Issue templates

| Template | For |
|---|---|
| Bug | Something behaves incorrectly |
| Feature | A capability that does not exist yet |
| Customer request (unrefined) | Raw customer ask — paste it verbatim and let triage work out the questions |
| Chore | Maintenance with no user-visible change |

Blank issues stay enabled: the `gh` CLI, the `file-issue` skill and agents all
create bare issues, and forcing them through a form would break every scripted path.

## Reusable workflows

| Workflow | Purpose |
|---|---|
| `issue-triage.yml` | Classify an issue, then plan it or ask what is missing |
| `deps-verify.yml` | Build and verify Renovate/Dependabot PRs. Never merges. |
| `pr-review.yml` | Second-opinion review, with a security pass on sensitive paths |

Called from a repo as:

```yaml
jobs:
  triage:
    uses: dodi-smart/.github/.github/workflows/issue-triage.yml@main
    secrets: inherit
```

### Why `.github/.github/`

Not a typo, and not removable. A `uses:` value is `{owner}/{repo}/{path}@{ref}`.
This repo is *named* `.github`, and GitHub requires every reusable workflow to
live in `.github/workflows/` of its source repo — so both segments contain it.

It is also the ecosystem norm; the same shape appears wherever a `.github` repo
hosts shared CI:

```yaml
uses: stylelint/.github/.github/workflows/call-lint.yml@ab79793
uses: craftcms/.github/.github/workflows/ci.yml@v3
```

`dodi-smart/.github/workflows/...` would resolve to a file at `workflows/` in the
repo root, which GitHub will not accept as a reusable workflow. The only way to
shorten the line is to host the workflows in a repo *not* named `.github` — which
puts org CI where nobody looks for it (DODI-00011).

Thin caller templates are in
`agent-skills/skills/repo-triage-setup/assets/workflows/`.

## Onboarding a repo

Ask Claude: *"Use repo-triage-setup to onboard dodi-smart/&lt;repo&gt;"*.
It dry-runs first and stops for confirmation.
