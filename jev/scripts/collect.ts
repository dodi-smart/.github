// Builds the labeled JSONL that `eval.ts` reads, from decisions already
// recorded by the workflow (the `jev-decisions` artifact) plus the ground
// truth the humans and agents settled on afterwards.
//
// This is an operator tool: run it by hand against a downloaded run of
// artifacts, never from CI, and never against a repository this package
// does not already have read access to.
//
// Layout expected under --runs-dir: one subfolder per issue number, each
// holding the `decisions.json` written by `node src/cli.ts triage ...`:
//   <runs-dir>/401/decisions.json
//   <runs-dir>/402/decisions.json
//   ...
//
// Ground truth is read from GitHub itself with `gh api graphql`, as of
// whenever this script runs, so run it well after triage, once a human or
// agent has had the chance to correct the fields the classifier suggested.
//
// Usage:
//   node scripts/collect.ts --repo <owner>/<name> --runs-dir ./runs --out labeled.jsonl

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import type { Decisions } from '../src/types.ts';

const QUERY = `
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      issueType { name }
      labels(first: 50) { nodes { name } }
      issueFieldValues(first: 50) {
        nodes {
          ... on IssueFieldSingleSelectValue {
            name
            field { ... on IssueFieldSingleSelect { name } }
          }
        }
      }
    }
  }
}`;

type IssueTruth = {
  type: string | null;
  areas: string[];
  fields: Record<string, string>;
};

function fetchTruth(owner: string, name: string, issueNumber: number): IssueTruth {
  const raw = execFileSync(
    'gh',
    ['api', 'graphql', '-f', `query=${QUERY}`, '-F', `owner=${owner}`, '-F', `name=${name}`, '-F', `number=${issueNumber}`],
    { encoding: 'utf8' },
  );
  const data = JSON.parse(raw) as {
    data: {
      repository: {
        issue: {
          issueType: { name: string } | null;
          labels: { nodes: { name: string }[] };
          issueFieldValues: { nodes: ({ name: string; field: { name: string } } | Record<string, never>)[] };
        };
      };
    };
  };
  const issue = data.data.repository.issue;
  const fields: Record<string, string> = {};
  for (const v of issue.issueFieldValues.nodes) {
    if ('name' in v && 'field' in v) fields[v.field.name] = v.name;
  }
  const areas = issue.labels.nodes.map((l) => l.name).filter((n) => n.startsWith('area:'));
  return { type: issue.issueType?.name ?? null, areas, fields };
}

function parseArgs(argv: string[]): { repo: string; runsDir: string; out: string } {
  const opts: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i];
    if (k?.startsWith('--')) opts[k.slice(2)] = argv[i + 1] ?? '';
  }
  if (!opts.repo || !opts['runs-dir']) throw new Error('--repo <owner>/<name> and --runs-dir <dir> are required');
  return { repo: opts.repo, runsDir: opts['runs-dir'], out: opts.out ?? 'labeled.jsonl' };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const [owner, name] = args.repo.split('/');
  if (!owner || !name) throw new Error('--repo must be owner/name');

  const lines: string[] = [];
  for (const issueDir of readdirSync(args.runsDir).sort()) {
    const issueNumber = Number(issueDir);
    if (!Number.isInteger(issueNumber)) continue;
    const decisionsPath = `${args.runsDir}/${issueDir}/decisions.json`;
    if (!existsSync(decisionsPath)) continue;

    const decisions = JSON.parse(readFileSync(decisionsPath, 'utf8')) as Decisions;
    if (decisions.task !== 'triage') continue;

    const truth = fetchTruth(owner, name, issueNumber);
    const expected: Record<string, unknown> = {};
    if (truth.type) expected.Type = truth.type;
    for (const [field, value] of Object.entries(truth.fields)) expected[field] = value;
    if (truth.areas.length) expected.areas = truth.areas;

    // `state` here is the model's raw answers, not a replayable TriageState, this
    // JSONL is meant for `eval.ts --from-decisions`, which never re-runs the task
    // and ignores `state`. Point `--from-decisions` at a directory of `<n>.json`
    // decisions files built from the same `runs-dir`, in this loop's issue order.
    lines.push(JSON.stringify({ task: 'triage', state: decisions.answers, expected }));
  }

  writeFileSync(args.out, lines.join('\n') + (lines.length ? '\n' : ''));
  console.log(`wrote ${lines.length} labeled line(s) to ${args.out}`);
}

main();
