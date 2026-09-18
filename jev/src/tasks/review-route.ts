// Review routing: decide review depth from the diff itself, before the agent.
//
// The workflow already raises depth for a path that matches a regex. This adds
// the case the regex cannot see: a policy, a migration or an auth check inside
// a file nobody listed. It also skips a diff that has nothing to review, and
// tells the agent when the description does not describe the diff.
//
// A sensitive diff is never skipped, whatever the trivial score says.

import { fitState } from '../budget.ts';
import { emptyDecisions, probabilityOf, rawAnswers, round } from '../common.ts';
import { reviewRoute } from '../policy.ts';
import type { Decisions, Mode, Question, Transport } from '../types.ts';

export type ReviewRouteState = {
  pr: { number: number; title: string; body: string | null; labels: string[]; files: string[] };
  diff: string;
  /** The depth the workflow chose deterministically, and the one it raises to. */
  level: string;
  elevatedLevel: string;
  reason?: string;
};

export function reviewRouteQuestions(): Record<string, Question> {
  return {
    sensitive: { type: 'boolean', instructions: reviewRoute.sensitive.instructions, criteria: reviewRoute.sensitive.criteria },
    trivial: { type: 'boolean', instructions: reviewRoute.trivial.instructions, criteria: reviewRoute.trivial.criteria },
    descriptionMatchesDiff: {
      type: 'boolean',
      instructions: reviewRoute.descriptionMatchesDiff.instructions,
      criteria: reviewRoute.descriptionMatchesDiff.criteria,
    },
  };
}

export function reviewRouteModelState(state: ReviewRouteState) {
  return fitState(
    {
      title: state.pr.title,
      body: state.pr.body ?? '',
      labels: state.pr.labels,
      changed_files: state.pr.files,
      diff: state.diff,
    },
    ['diff', 'body'],
  );
}

export async function runReviewRoute(state: ReviewRouteState, mode: Mode, transport: Transport): Promise<Decisions> {
  const { state: modelState, truncated } = reviewRouteModelState(state);
  const d = emptyDecisions('review-route', mode, modelState, truncated);
  const ev = await transport(modelState, reviewRouteQuestions());
  d.latencyMs = ev.latencyMs;
  d.model = ev.modelId || d.model;
  d.answers = rawAnswers(ev);
  const active = mode === 'active';

  const sensitive = probabilityOf(ev.answers.sensitive);
  const trivial = probabilityOf(ev.answers.trivial);
  const match = probabilityOf(ev.answers.descriptionMatchesDiff);
  d.extra.sensitive = round(sensitive);
  d.extra.trivial = round(trivial);
  d.extra.descriptionMatchesDiff = round(match);

  const raise = sensitive >= reviewRoute.sensitive.threshold;
  d.extra.level = active && raise ? state.elevatedLevel : state.level;
  d.extra.reason = raise ? `${state.reason ?? ''}${state.reason ? '; ' : ''}jev: sensitive diff ${round(sensitive)}`.trim() : state.reason ?? '';

  // A truncated diff was not fully read, so it is never trivial.
  if (active && !raise && !truncated && trivial >= reviewRoute.trivial.threshold) {
    d.route = 'skip';
    d.routeReason = `trivial ${round(trivial)}`;
    d.extra.skipComment = reviewRoute.trivial.comment;
  }

  d.extra.descriptionMismatch = match < reviewRoute.descriptionMatchesDiff.threshold;
  return d;
}
