// Records `response.json` fixtures by running the real task through the
// gateway against each fixture's `state.json`.
//
// NEVER RUN THIS IN CI. It needs AI_GATEWAY_API_KEY and makes a live network
// call per fixture case; it exists for a person updating fixtures by hand,
// not for a workflow.
//
// Usage (from the package root):
//   AI_GATEWAY_API_KEY=... node scripts/record.ts
//   AI_GATEWAY_API_KEY=... node scripts/record.ts --task triage --case clear-bug

import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { gatewayTransport } from '../src/gateway.ts';
import { reviewCheckModelState, reviewCheckQuestions } from '../src/tasks/review-check.ts';
import { reviewRouteModelState, reviewRouteQuestions } from '../src/tasks/review-route.ts';
import { triageModelState, triageQuestions, type TriageState } from '../src/tasks/triage.ts';
import type { Answer, Question, Task } from '../src/types.ts';

const FIXTURES_DIR = fileURLToPath(new URL('../tests/fixtures/', import.meta.url));
const TASKS: readonly Task[] = ['triage', 'review-route', 'review-check'];

function questionsAndState(task: Task, state: unknown): { modelState: unknown; questions: Record<string, Question> } {
  if (task === 'triage') {
    const s = state as TriageState;
    return { modelState: triageModelState(s).state, questions: triageQuestions(s) };
  }
  if (task === 'review-route') {
    return { modelState: reviewRouteModelState(state as never).state, questions: reviewRouteQuestions() };
  }
  return { modelState: reviewCheckModelState(state as never).state, questions: reviewCheckQuestions() };
}

function parseArgs(argv: string[]): { task?: Task; case?: string } {
  const out: { task?: Task; case?: string } = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === '--task') out.task = argv[i + 1] as Task;
    if (argv[i] === '--case') out.case = argv[i + 1];
  }
  return out;
}

async function recordOne(task: Task, caseName: string, apiKey: string) {
  const dir = new URL(`${task}/${caseName}/`, `file://${FIXTURES_DIR}`);
  const state = JSON.parse(readFileSync(new URL('state.json', dir), 'utf8'));
  const { modelState, questions } = questionsAndState(task, state);
  const transport = gatewayTransport(apiKey);
  const ev = await transport(modelState, questions);
  const recorded = {
    answers: ev.answers as Record<string, Answer>,
    confidence: ev.confidence,
    usage: ev.usage,
    modelId: ev.modelId,
  };
  writeFileSync(new URL('response.json', dir), JSON.stringify(recorded, null, 2) + '\n');
  console.log(`recorded ${task}/${caseName} (${ev.modelId}, ${ev.latencyMs}ms)`);
}

async function main() {
  const apiKey = process.env.AI_GATEWAY_API_KEY;
  if (!apiKey) {
    console.error('AI_GATEWAY_API_KEY is not set. This script makes live gateway calls and refuses to run without a key.');
    process.exit(1);
  }
  const args = parseArgs(process.argv.slice(2));
  const tasks = args.task ? [args.task] : TASKS;
  for (const task of tasks) {
    const cases = args.case ? [args.case] : readdirSync(new URL(`${task}/`, `file://${FIXTURES_DIR}`)).sort();
    for (const caseName of cases) {
      await recordOne(task, caseName, apiKey);
    }
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
