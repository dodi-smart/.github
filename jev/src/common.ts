// Helpers shared by the tasks. Small on purpose; the policy is in policy.ts
// and the task files only assemble questions and read answers.

import { hashState } from './budget.ts';
import { MODEL_ID, POLICY_VERSION, type ChoiceField } from './policy.ts';
import type { Answer, Decisions, Evaluation, Mode, Question, Task } from './types.ts';

export function choiceQuestion(field: ChoiceField): Question {
  return { type: 'choice', instructions: field.instructions, criteria: field.options };
}

/** The provider's confidence when it sent one, else the winning option's probability. */
export function confidenceOf(answer: Answer | undefined, provided: number | undefined): number {
  if (typeof provided === 'number') return provided;
  if (!answer) return 0;
  if (answer.type === 'boolean') return Math.max(answer.probability, 1 - answer.probability);
  if (answer.type === 'choice') return answer.probabilities?.[answer.choice] ?? 0;
  const top = Object.values(answer.probabilities ?? {});
  return top.length ? Math.max(...top) : 0;
}

export function probabilityOf(answer: Answer | undefined): number {
  return answer?.type === 'boolean' ? answer.probability : 0;
}

export function scoreOf(answer: Answer | undefined): number {
  return answer?.type === 'score' ? answer.score : 0;
}

export function round(n: number): number {
  return Math.round(n * 100) / 100;
}

/** A decisions record with nothing decided yet. Tasks fill the rest. */
export function emptyDecisions(task: Task, mode: Mode, state: unknown, truncated: boolean): Decisions {
  return {
    task,
    mode,
    model: MODEL_ID,
    policyVersion: POLICY_VERSION,
    stateHash: hashState(state),
    truncated,
    latencyMs: 0,
    route: 'agent',
    routeReason: '',
    fields: [],
    type: null,
    labels: { add: [], remove: [] },
    extra: {},
    answers: {},
  };
}

/** Raw answers plus confidence, for the calibration set. */
export function rawAnswers(ev: Evaluation): Decisions['answers'] {
  const out: Decisions['answers'] = {};
  for (const [id, a] of Object.entries(ev.answers)) {
    out[id] = ev.confidence[id] === undefined ? a : { ...a, confidence: ev.confidence[id] };
  }
  return out;
}
