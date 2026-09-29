#!/usr/bin/env node
// Usage:
//   node src/cli.ts <triage|review-route|review-check> --state <file.json> --out <decisions.json>
//                   [--mode active|shadow] [--summary <file.md>] [--github-output <file>]
//
// Reads AI_GATEWAY_API_KEY from the environment. Exits 0 on every path: a
// missing key, a gateway error or a bad state file all produce a decisions
// record with `notEvaluated` set and a `::warning`, because the classifier
// accelerates a run that already works without it, and a red job for an
// optional dependency teaches people to delete the dependency. The one exit 2
// is a usage error, which is a bug in the caller, not a runtime condition.

import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { gatewayTransport } from './gateway.ts';
import { githubOutput, promptBlock, summary } from './render.ts';
import { runReviewCheck } from './tasks/review-check.ts';
import { runReviewRoute } from './tasks/review-route.ts';
import { runTriage } from './tasks/triage.ts';
import type { Decisions, Mode, Task, Transport } from './types.ts';
import { emptyDecisions } from './common.ts';

const TASKS = new Set<Task>(['triage', 'review-route', 'review-check']);

export function parseArgs(argv: string[]) {
  const [task, ...rest] = argv;
  const opts: Record<string, string> = {};
  for (let i = 0; i < rest.length; i += 2) {
    const k = rest[i];
    const v = rest[i + 1];
    if (!k?.startsWith('--') || v === undefined) throw new Error(`bad argument near ${k ?? '(end)'}`);
    opts[k.slice(2)] = v;
  }
  if (!task || !TASKS.has(task as Task)) throw new Error(`task must be one of ${[...TASKS].join(', ')}`);
  if (!opts.state || !opts.out) throw new Error('--state and --out are required');
  const mode = (opts.mode ?? 'active') as Mode;
  if (mode !== 'active' && mode !== 'shadow') throw new Error('--mode must be active or shadow');
  return { task: task as Task, state: opts.state, out: opts.out, mode, summary: opts.summary, githubOutput: opts['github-output'] };
}

export async function run(task: Task, state: unknown, mode: Mode, transport: Transport): Promise<Decisions> {
  if (task === 'triage') return runTriage(state as never, mode, transport);
  if (task === 'review-route') return runReviewRoute(state as never, mode, transport);
  return runReviewCheck(state as never, mode, transport);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let state: unknown = {};
  let decisions: Decisions;
  try {
    state = JSON.parse(readFileSync(args.state, 'utf8'));
    const key = process.env.AI_GATEWAY_API_KEY ?? '';
    if (!key) throw new Error('AI_GATEWAY_API_KEY is not set');
    decisions = await run(args.task, state, args.mode, gatewayTransport(key));
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    decisions = emptyDecisions(args.task, args.mode, state, false);
    decisions.notEvaluated = reason;
    console.log(`::warning title=jev did not run::${reason.replace(/\r?\n/g, ' ')}. The agent proceeds as before.`);
  }
  writeFileSync(args.out, JSON.stringify(decisions, null, 2) + '\n');
  if (args.summary) appendFileSync(args.summary, summary(decisions));
  if (args.githubOutput) appendFileSync(args.githubOutput, githubOutput(decisions));
  console.log(promptBlock(decisions));
}

if (process.argv[1] && /cli\.ts$/.test(process.argv[1])) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(2);
  });
}
