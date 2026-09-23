// Review check: read the verdict the agent wrote, before the job posts it.
//
// Two questions, and the answers only annotate. A checker that can fail the
// run becomes a second reviewer with veto power and no accountability, so
// this one writes a line under the verdict and leaves the decision to the
// person reading it.

import { fitState } from '../budget.ts';
import { emptyDecisions, probabilityOf, rawAnswers, round, scoreOf } from '../common.ts';
import { reviewCheck } from '../policy.ts';
import type { Decisions, Mode, Question, Transport } from '../types.ts';

export type ReviewCheckState = {
  /** The verdict file the agent wrote. */
  verdict: string;
  inlineComments: number;
  ciSummary?: string;
  level?: string;
};

export function reviewCheckQuestions(): Record<string, Question> {
  return {
    verdictConsistent: {
      type: 'boolean',
      instructions: reviewCheck.verdictConsistent.instructions,
      criteria: reviewCheck.verdictConsistent.criteria,
    },
    slop: { type: 'score', instructions: reviewCheck.slop.instructions, criteria: reviewCheck.slop.criteria },
  };
}

export function reviewCheckModelState(state: ReviewCheckState) {
  return fitState(
    {
      review: state.verdict,
      inline_comment_count: String(state.inlineComments),
      ci_summary: state.ciSummary ?? '',
    },
    ['review', 'ci_summary'],
  );
}

export async function runReviewCheck(state: ReviewCheckState, mode: Mode, transport: Transport): Promise<Decisions> {
  const { state: modelState, truncated } = reviewCheckModelState(state);
  const d = emptyDecisions('review-check', mode, modelState, truncated);
  const ev = await transport(modelState, reviewCheckQuestions());
  d.latencyMs = ev.latencyMs;
  d.model = ev.modelId || d.model;
  d.answers = rawAnswers(ev);

  const consistent = probabilityOf(ev.answers.verdictConsistent);
  const slop = scoreOf(ev.answers.slop);
  d.extra.verdictConsistent = round(consistent);
  d.extra.slop = round(slop);

  const notes: string[] = [];
  if (consistent < reviewCheck.verdictConsistent.threshold) {
    notes.push(`The verdict line and the findings under it disagree (agreement ${round(consistent)}). Read the findings, not the first line.`);
  }
  if (slop >= reviewCheck.slop.reportLevel) {
    notes.push(`This review carries filler (house-style score ${round(slop)} of 3). The findings are in there; skim past the rest.`);
  }
  d.extra.note = notes.join('\n');
  return d;
}
