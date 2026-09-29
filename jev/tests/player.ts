// A `Transport` that plays back a recorded fixture instead of calling the
// gateway. Every test in this package runs against fixtures, never the
// network, so `fixtureTransport` is the one seam between the task code and
// `tests/fixtures/<task>/<case>/`.

import { readFileSync } from 'node:fs';
import type { Answer, Evaluation, Question, Task, Transport } from '../src/types.ts';

type RecordedResponse = {
  answers: Record<string, Answer>;
  confidence: Record<string, number>;
  usage: { inputTokens?: number; outputTokens?: number };
  modelId: string;
};

function fixtureDir(task: Task, caseName: string): URL {
  return new URL(`./fixtures/${task}/${caseName}/`, import.meta.url);
}

function readJson<T>(task: Task, caseName: string, file: string): T {
  const url = new URL(file, fixtureDir(task, caseName));
  return JSON.parse(readFileSync(url, 'utf8')) as T;
}

export function loadState<T = unknown>(task: Task, caseName: string): T {
  return readJson<T>(task, caseName, 'state.json');
}

export function loadExpected<T = unknown>(task: Task, caseName: string): T {
  return readJson<T>(task, caseName, 'expected.json');
}

/**
 * A `Transport` that reads `tests/fixtures/<task>/<case>/response.json` and
 * hands it back as an `Evaluation` with `latencyMs: 0`.
 *
 * It throws if the set of question ids the task asked for differs from the
 * set of answer ids recorded in the fixture, in either direction. Silently
 * answering a question nobody asked, or silently leaving one unanswered,
 * would let a fixture drift from the code it is meant to pin.
 */
export function fixtureTransport(task: Task, caseName: string): Transport {
  const recorded = readJson<RecordedResponse>(task, caseName, 'response.json');
  return async (_state: unknown, questions: Record<string, Question>): Promise<Evaluation> => {
    const asked = new Set(Object.keys(questions));
    const answered = new Set(Object.keys(recorded.answers));
    const missing = [...asked].filter((id) => !answered.has(id));
    const extra = [...answered].filter((id) => !asked.has(id));
    if (missing.length || extra.length) {
      const parts: string[] = [];
      if (missing.length) parts.push(`asked but not recorded: ${missing.join(', ')}`);
      if (extra.length) parts.push(`recorded but not asked: ${extra.join(', ')}`);
      throw new Error(`fixture ${task}/${caseName}/response.json does not match the questions asked (${parts.join('; ')})`);
    }
    return {
      answers: recorded.answers,
      confidence: recorded.confidence,
      usage: recorded.usage,
      modelId: recorded.modelId,
      latencyMs: 0,
    };
  };
}
