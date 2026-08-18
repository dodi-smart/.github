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

The doubled `.github/.github/` is correct — it is the repo name followed by the
workflow path inside it.

Thin caller templates are in
`agent-skills/skills/repo-triage-setup/assets/workflows/`.

## Onboarding a repo

Ask Claude: *"Use repo-triage-setup to onboard dodi-smart/&lt;repo&gt;"*.
It dry-runs first and stops for confirmation.
