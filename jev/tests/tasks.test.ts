import { readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { fixtureTransport, loadExpected, loadState } from './player.ts';
import { routes } from '../src/policy.ts';
import { runReviewCheck } from '../src/tasks/review-check.ts';
import { runReviewRoute } from '../src/tasks/review-route.ts';
import { runTriage, triageQuestions, type TriageState } from '../src/tasks/triage.ts';
import type { Mode, Task } from '../src/types.ts';

function cases(task: Task): string[] {
  return readdirSync(new URL(`./fixtures/${task}/`, import.meta.url)).sort();
}

type TriageExpected = {
  mode?: Mode;
  route: 'agent' | 'skip';
  routeReasonContains?: string;
  skipCommentFrom?: 'injection' | 'spam';
  type: { value: string; act: boolean };
  fields: Record<string, { value: string; act: boolean; suggest?: boolean }>;
  labelsAdd: string[];
};

describe('triage', () => {
  for (const caseName of cases('triage')) {
    it(caseName, async () => {
      const state = loadState<TriageState>('triage', caseName);
      const expected = loadExpected<TriageExpected>('triage', caseName);
      const mode: Mode = expected.mode ?? 'active';
      const d = await runTriage(state, mode, fixtureTransport('triage', caseName));

      expect(d.route).toBe(expected.route);
      if (expected.routeReasonContains) expect(d.routeReason).toContain(expected.routeReasonContains);
      if (expected.skipCommentFrom) expect(d.extra.skipComment).toBe(routes[expected.skipCommentFrom].comment);

      expect(d.type).not.toBeNull();
      expect(d.type?.value).toBe(expected.type.value);
      expect(d.type?.act).toBe(expected.type.act);

      for (const [name, want] of Object.entries(expected.fields)) {
        const got = d.fields.find((f) => f.name === name);
        expect(got, `field ${name} should be present`).toBeDefined();
        expect(got?.value).toBe(want.value);
        expect(got?.act).toBe(want.act);
        expect(!!got?.suggest).toBe(!!want.suggest);
      }

      expect(d.labels.add.sort()).toEqual([...expected.labelsAdd].sort());
    });
  }

  it('omits injection and spam for a Bot author, and asks one area_<name> per area', () => {
    const state = loadState<TriageState>('triage', 'clear-bug');
    const q = triageQuestions({ ...state, issue: { ...state.issue, authorType: 'Bot' } });
    expect(q.injection).toBeUndefined();
    expect(q.spam).toBeUndefined();
    for (const area of state.areas?.areas ?? []) {
      expect(q[`area_${area.name}`]).toBeDefined();
    }

    const humanQuestions = triageQuestions(state);
    expect(humanQuestions.injection).toBeDefined();
    expect(humanQuestions.spam).toBeDefined();
  });
});

type ReviewRouteExpected = {
  mode?: Mode;
  route: 'agent' | 'skip';
  routeReasonContains?: string;
  level: string;
  reasonContains?: string;
  descriptionMismatch: boolean;
};

describe('review-route', () => {
  for (const caseName of cases('review-route')) {
    it(caseName, async () => {
      const state = loadState('review-route', caseName);
      const expected = loadExpected<ReviewRouteExpected>('review-route', caseName);
      const mode: Mode = expected.mode ?? 'active';
      const d = await runReviewRoute(state as never, mode, fixtureTransport('review-route', caseName));

      expect(d.route).toBe(expected.route);
      if (expected.routeReasonContains) expect(d.routeReason).toContain(expected.routeReasonContains);
      expect(d.extra.level).toBe(expected.level);
      if (expected.reasonContains) expect(String(d.extra.reason)).toContain(expected.reasonContains);
      expect(d.extra.descriptionMismatch).toBe(expected.descriptionMismatch);
    });
  }
});

type ReviewCheckExpected = {
  mode?: Mode;
  noteContains?: string;
  noteExcludes?: string;
  noteEmpty?: boolean;
};

describe('review-check', () => {
  for (const caseName of cases('review-check')) {
    it(caseName, async () => {
      const state = loadState('review-check', caseName);
      const expected = loadExpected<ReviewCheckExpected>('review-check', caseName);
      const mode: Mode = expected.mode ?? 'active';
      const d = await runReviewCheck(state as never, mode, fixtureTransport('review-check', caseName));

      const note = String(d.extra.note ?? '');
      if (expected.noteEmpty) expect(note).toBe('');
      if (expected.noteContains) expect(note).toContain(expected.noteContains);
      if (expected.noteExcludes) expect(note).not.toContain(expected.noteExcludes);
    });
  }
});
