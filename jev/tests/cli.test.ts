import { describe, expect, it } from 'vitest';
import { parseArgs } from '../src/cli.ts';

describe('parseArgs', () => {
  it('accepts the documented form', () => {
    const args = parseArgs([
      'triage',
      '--state', 'state.json',
      '--out', 'decisions.json',
      '--mode', 'shadow',
      '--summary', 'summary.md',
      '--github-output', 'gh-out.txt',
    ]);
    expect(args).toEqual({
      task: 'triage',
      state: 'state.json',
      out: 'decisions.json',
      mode: 'shadow',
      summary: 'summary.md',
      githubOutput: 'gh-out.txt',
    });
  });

  it('defaults mode to active and leaves summary/github-output undefined', () => {
    const args = parseArgs(['review-route', '--state', 's.json', '--out', 'o.json']);
    expect(args.mode).toBe('active');
    expect(args.summary).toBeUndefined();
    expect(args.githubOutput).toBeUndefined();
  });

  it('rejects an unknown task', () => {
    expect(() => parseArgs(['not-a-task', '--state', 's.json', '--out', 'o.json'])).toThrow(/task must be one of/);
  });

  it('rejects a missing --state', () => {
    expect(() => parseArgs(['triage', '--out', 'o.json'])).toThrow(/--state and --out are required/);
  });

  it('rejects a missing --out', () => {
    expect(() => parseArgs(['triage', '--state', 's.json'])).toThrow(/--state and --out are required/);
  });

  it('rejects a bad --mode', () => {
    expect(() => parseArgs(['triage', '--state', 's.json', '--out', 'o.json', '--mode', 'sneaky'])).toThrow(/--mode must be active or shadow/);
  });

  it('rejects a dangling flag with no value', () => {
    expect(() => parseArgs(['triage', '--state'])).toThrow(/bad argument/);
  });
});
