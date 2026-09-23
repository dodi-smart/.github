// Triage: classify an issue before the agent reads it.
//
// The job writes what comes back at or above threshold; the agent is told
// what was set and what is still open. Nothing here writes `Triage state`,
// `Agent mode` or a `needs:*` label. Those need the plan-or-questions
// judgement the agent makes, and the verify step downstream depends on the
// agent being the one that recorded them.
//
// Fields already holding a value are never overwritten. A template or a human
// put that value there, and a classifier that disagrees with a human belongs
// in the calibration report, not on the issue.

import { fitState } from '../budget.ts';
import { choiceQuestion, confidenceOf, emptyDecisions, probabilityOf, rawAnswers, round } from '../common.ts';
import { area, FIELD_THRESHOLD, fields, routes, typeField } from '../policy.ts';
import type { Decisions, FieldDecision, Mode, Question, Transport } from '../types.ts';

export type Area = { name: string; description?: string; paths?: string[] };

export type TriageState = {
  issue: {
    number: number;
    title: string;
    body: string | null;
    /** GitHub's `user.type`: "User" or "Bot". */
    authorType: string;
    labels: string[];
    type: string | null;
    action?: string;
  };
  /** Current single-select values by field name. Empty object when none are set. */
  fields: Record<string, string>;
  /** The repo's area vocabulary, or null when `.github/areas.yml` is absent. */
  areas: { areas: Area[]; rules?: string[] } | null;
  /** Recent comments, present only on a reopened issue. */
  comments?: { author: string; body: string }[];
};

const AREA_PREFIX = 'area_';

export function triageQuestions(state: TriageState): Record<string, Question> {
  const q: Record<string, Question> = {};
  const human = state.issue.authorType !== 'Bot';
  if (human) {
    q.injection = { type: 'boolean', instructions: routes.injection.instructions, criteria: routes.injection.criteria };
    q.spam = { type: 'boolean', instructions: routes.spam.instructions, criteria: routes.spam.criteria };
  }
  q.type = choiceQuestion(typeField);
  for (const f of fields) q[f.name] = choiceQuestion(f);
  for (const a of state.areas?.areas ?? []) {
    q[AREA_PREFIX + a.name] = {
      type: 'boolean',
      instructions: area.instructions
        .replace('{name}', a.name)
        .replace('{description}', a.description ?? 'no description')
        .replace('{paths}', (a.paths ?? []).join(', ') || 'none listed'),
      criteria: area.criteria,
    };
  }
  return q;
}

/** What the model sees. The issue text and the vocabulary rules, nothing about the pipeline. */
export function triageModelState(state: TriageState) {
  const base = {
    title: state.issue.title,
    body: state.issue.body ?? '',
    author_type: state.issue.authorType,
    existing_labels: state.issue.labels,
    existing_type: state.issue.type ?? '',
    area_rules: (state.areas?.rules ?? []).join('\n'),
    recent_comments: (state.comments ?? []).map((c) => `${c.author}: ${c.body}`).join('\n---\n'),
  };
  return fitState(base, ['body', 'recent_comments', 'area_rules']);
}

export async function runTriage(state: TriageState, mode: Mode, transport: Transport): Promise<Decisions> {
  const { state: modelState, truncated } = triageModelState(state);
  const questions = triageQuestions(state);
  const d = emptyDecisions('triage', mode, modelState, truncated);
  const ev = await transport(modelState, questions);
  d.latencyMs = ev.latencyMs;
  d.model = ev.modelId || d.model;
  d.answers = rawAnswers(ev);
  const active = mode === 'active';

  for (const key of ['injection', 'spam'] as const) {
    const p = probabilityOf(ev.answers[key]);
    d.extra[key] = round(p);
    if (d.route === 'agent' && questions[key] && p >= routes[key].threshold) {
      d.route = active ? 'skip' : 'agent';
      d.routeReason = `${key} ${round(p)}`;
      d.extra.skipComment = routes[key].comment;
    }
  }

  const typeAnswer = ev.answers.type;
  if (typeAnswer?.type === 'choice') {
    const confidence = round(confidenceOf(typeAnswer, ev.confidence.type));
    const already = !!state.issue.type;
    d.type = { value: typeAnswer.choice, confidence, act: active && !already && confidence >= FIELD_THRESHOLD };
  }

  for (const f of fields) {
    const a = ev.answers[f.name];
    if (a?.type !== 'choice') continue;
    const confidence = round(confidenceOf(a, ev.confidence[f.name]));
    const already = !!state.fields[f.name];
    const decision: FieldDecision = {
      name: f.name,
      value: a.choice,
      confidence,
      act: active && !already && confidence >= FIELD_THRESHOLD,
    };
    if (!decision.act && f.suggestBelowThreshold?.includes(a.choice)) decision.suggest = true;
    d.fields.push(decision);
  }

  for (const a of state.areas?.areas ?? []) {
    const p = probabilityOf(ev.answers[AREA_PREFIX + a.name]);
    const label = 'area:' + a.name;
    if (p >= area.threshold && !state.issue.labels.includes(label) && active) d.labels.add.push(label);
  }

  return d;
}
