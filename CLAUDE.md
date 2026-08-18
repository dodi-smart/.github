# Agent instructions

## This repo is an extension of `dodi-smart/dev-standards`

It is not a separate project. It exists because GitHub mandates two fixed
locations, and only these two things live here:

- `.github/ISSUE_TEMPLATE/` — inherited org-wide; only a repo literally named
  `.github` provides that
- `.github/workflows/` — the reusable workflows, kept here because this is where
  people look for org CI

**Everything else — the skills, the label manifest, the scripts, and all the
reasoning — lives in [`dodi-smart/dev-standards`](https://github.com/dodi-smart/dev-standards).**
Read that repo's `CLAUDE.md` before changing anything here.

## The `.github/.github/` in every caller is correct

`uses:` is `{owner}/{repo}/{path}@{ref}`. This repo is named `.github`, and
GitHub requires reusable workflows to live in `.github/workflows/` of the source
repo — so the segment appears twice, once as the repo and once as the path. Do
not "fix" it to `dodi-smart/.github/workflows/...`; that path does not resolve.

## There is one knowledge layer, and it is not in this repo

Decisions live in `dev-standards/.zavet/`, with ids `DODI-NNNNN`. This repo
deliberately has no `.zavet/` of its own: two sequences sharing the `DODI` prefix
would eventually both mint the same id, and a citation would stop resolving to a
single record.

So the records governing the files here cannot inject themselves automatically.
Read them before editing:

| File | Governed by |
|---|---|
| `.github/workflows/deps-verify.yml` | **DODI-00004** — verification never confers merge authority. This workflow must never merge, approve, or change mergeability. |
| all three workflows | **DODI-00005** — deterministic gates run before any agent step, and the runner picker carries the same `if:` as the job it feeds. |
| all three workflows | **DODI-00008** — `agent:no-touch` is checked before every other condition, with no exemption. |
| all three workflows | **DODI-00010** — runners are selected by generic capability (`self-hosted,Linux,ARM64` light, `Linux,X64` heavy); public repos and fork PRs always use hosted. |
| `.github/workflows/pr-review.yml` | **DODI-00005** — no `synchronize` trigger. Reviewing every push is what got the previous review workflow muted. |

Those decisions carry executable checks that fetch these files over the API, so
they are verified rather than assumed. Run them from `dev-standards`:

```bash
.zavet/check.sh
```

## If you add a workflow here

Add its governing decision ids to the table above, and add a check in
`dev-standards` that fetches it. A workflow nobody recorded a reason for is one
the next person will "simplify".
