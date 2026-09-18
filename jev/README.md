# jev

Typed, probabilistic pre-classification for the agent workflows. `jev`
stands in ahead of an agent: it asks a small set of yes/no, choice or score
questions about an issue or a pull request, and writes back only the answers
it is confident about. Everything below a threshold is left for the agent to
decide, the way it always has.

Nothing here is built. The package runs straight from TypeScript source with
Node's native `.ts` support (`node src/cli.ts ...`), and the test suite runs
the same way.

## Layout

- `src/policy.ts`, every question, option and threshold, in one file.
- `src/tasks/`, one file per task: `triage`, `review-route`, `review-check`.
- `src/gateway.ts`, the only module that talks to the model, through the
  Vercel AI Gateway. Everything else takes a `Transport` function, so tests
  never touch the network.
- `src/cli.ts`, the entry point a workflow calls.
- `tests/`, fixture-driven tests, one fixture directory per case, plus a
  small player (`tests/player.ts`) that turns a fixture into a `Transport`.
- `scripts/`, operator tools, never run in CI: `record.ts` records fixture
  responses from the real model, `eval.ts` reports accuracy against a labeled
  set, `collect.ts` builds that labeled set from a repository's history.

## Running the CLI

```
node src/cli.ts <triage|review-route|review-check> \
  --state <state.json> --out <decisions.json> \
  [--mode active|shadow] [--summary <file.md>] [--github-output <file>]
```

`--state` is the task-specific state object (see the `*State` types in
`src/tasks/*.ts`). `AI_GATEWAY_API_KEY` must be set in the environment; if it
is missing, or the gateway call fails, the CLI still exits 0 and writes a
decisions record with `notEvaluated` set, so a missing or broken classifier
never fails a workflow run.

## Tests

```
./node_modules/.bin/vitest run
./node_modules/.bin/tsc -p tsconfig.json
```

Every test runs against a fixture under `tests/fixtures/<task>/<case>/`:
`state.json` (the task's input), `response.json` (a recorded model answer)
and `expected.json` (what the test asserts). `tests/player.ts` exposes
`fixtureTransport(task, case)`, which plays `response.json` back as a
`Transport` and throws if the fixture's answers do not cover exactly the
questions the task asked, so a fixture can never go stale silently.

`tests/policy.test.ts` pins the confidence floors in `src/policy.ts`.
Lowering one of them needs that test changed, and a reason given in the
commit message.

## Recording fixtures

`scripts/record.ts` runs the real task against a fixture's `state.json`
through the gateway and overwrites its `response.json`. It needs
`AI_GATEWAY_API_KEY` and makes a live network call per case, so it is never
run in CI:

```
AI_GATEWAY_API_KEY=... node scripts/record.ts                       # every fixture
AI_GATEWAY_API_KEY=... node scripts/record.ts --task triage --case clear-bug
```

After recording, update the matching `expected.json` by hand if the model's
answer changed which branch the task takes.

## Evaluating against a labeled set

`scripts/eval.ts` reports, for each choice field and a range of confidence
thresholds, how much of a labeled set is covered at that threshold and how
accurate the covered items are, plus area-label precision/recall and route
accuracy:

```
node scripts/eval.ts --input labeled.jsonl                       # live, needs AI_GATEWAY_API_KEY
node scripts/eval.ts --input labeled.jsonl --from-decisions dir   # replay recorded decisions
```

The input is JSON Lines; see `tests/fixtures/eval-sample.jsonl` for the
shape. `scripts/collect.ts` builds a labeled set from a repository's own
history: point it at a directory of downloaded `jev-decisions` artifacts,
one subfolder per issue number, and it reads each issue's final type,
fields and area labels with `gh api graphql` as the ground truth.
