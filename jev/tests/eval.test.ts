import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { computeTable, readJsonl } from '../scripts/eval.ts';
import { emptyDecisions } from '../src/common.ts';
import type { Decisions } from '../src/types.ts';

const SAMPLE = fileURLToPath(new URL('./fixtures/eval-sample.jsonl', import.meta.url));

function triageDecisions(overrides: Partial<Decisions> = {}): Decisions {
  return { ...emptyDecisions('triage', 'active', {}, false), ...overrides };
}

describe('readJsonl', () => {
  it('parses each line of eval-sample.jsonl into an EvalItem', () => {
    const items = readJsonl(SAMPLE);
    expect(items).toHaveLength(3);
    expect(items[0]!.task).toBe('triage');
    expect(items[0]!.expected).toEqual({ Type: 'Bug', Priority: 'High', areas: ['area:ledger'], route: 'agent' });
    expect(items[2]!.expected.route).toBe('skip');
  });
});

describe('computeTable', () => {
  it('reports full coverage and accuracy when every decision matches at high confidence', () => {
    const items = readJsonl(SAMPLE);
    const decisions: Decisions[] = [
      triageDecisions({
        route: 'agent',
        type: { value: 'Bug', confidence: 0.95, act: true },
        fields: [{ name: 'Priority', value: 'High', confidence: 0.92, act: true }],
        labels: { add: ['area:ledger'], remove: [] },
      }),
      triageDecisions({
        route: 'agent',
        type: { value: 'Feature', confidence: 0.93, act: true },
        fields: [{ name: 'Priority', value: 'Low', confidence: 0.91, act: true }],
        labels: { add: [], remove: [] },
      }),
      triageDecisions({
        route: 'skip',
        type: { value: 'Task', confidence: 0.94, act: false },
        fields: [{ name: 'Priority', value: 'Low', confidence: 0.9, act: false }],
        labels: { add: ['area:onboarding'], remove: [] },
      }),
    ];

    const table = computeTable(items, decisions);
    expect(table).toContain('Type (n=3)');
    expect(table).toContain('Priority (n=3)');
    expect(table).toMatch(/0\.90\s+100%\s+100%\s+3\/3/);
    expect(table).toContain('area labels at AREA_THRESHOLD');
    expect(table).toContain('precision 100%, recall 100% (tp=2 fp=0 fn=0)');
    expect(table).toContain('route: 100% (3/3)');
  });

  it('counts a wrong prediction as covered but inaccurate, and a low-confidence one as uncovered', () => {
    const items = readJsonl(SAMPLE).slice(0, 1);
    const decisions: Decisions[] = [
      triageDecisions({
        route: 'agent',
        type: { value: 'Feature', confidence: 0.95, act: true },
        fields: [{ name: 'Priority', value: 'High', confidence: 0.6, act: false }],
        labels: { add: [], remove: [] },
      }),
    ];
    const table = computeTable(items, decisions);
    // Type: wrong value (Feature vs Bug), but confident enough to be covered at 0.90.
    expect(table).toMatch(/0\.90\s+100%\s+0%\s+1\/1/);
    // Priority: right value, but 0.6 confidence falls below the 0.65 threshold, so it is not covered there.
    expect(table).toMatch(/0\.65\s+0%\s+0%\s+0\/1/);
    expect(table).toMatch(/0\.60\s+100%\s+100%\s+1\/1/);
  });

  it('throws when items and decisions have different lengths', () => {
    expect(() => computeTable(readJsonl(SAMPLE), [])).toThrow(/same length/);
  });
});
