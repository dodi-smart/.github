import { describe, expect, it } from 'vitest';
import { fitState } from '../src/budget.ts';
import { liftConfidence } from '../src/gateway.ts';

describe('fitState', () => {
  it('leaves a small state untouched', () => {
    const state = { title: 'short', body: 'also short', count: 3 };
    const { state: out, truncated } = fitState(state, ['title', 'body']);
    expect(out).toEqual(state);
    expect(out).not.toBe(state);
    expect(truncated).toBe(false);
  });

  it('cuts the largest text field first and never touches non-text fields', () => {
    const state = {
      short: 'x'.repeat(100),
      long: 'y'.repeat(200_000),
      count: 42,
      flags: ['a', 'b'],
    };
    const { state: out, truncated } = fitState(state, ['short', 'long'], 50_000);
    expect(truncated).toBe(true);
    expect(out.short).toBe(state.short);
    expect(out.long.length).toBeLessThan(state.long.length);
    expect(out.long).toContain('[cut: state exceeded the model window]');
    expect(out.count).toBe(42);
    expect(out.flags).toEqual(['a', 'b']);
  });

  it('does not mutate the input', () => {
    const state = { long: 'z'.repeat(200_000) };
    const before = { ...state };
    fitState(state, ['long'], 1000);
    expect(state).toEqual(before);
  });
});

describe('liftConfidence', () => {
  it('reads providerMetadata.typesafe.confidence when present', () => {
    const meta = { typesafe: { confidence: { type: 0.9, Priority: 0.5 } } };
    expect(liftConfidence(meta)).toEqual({ type: 0.9, Priority: 0.5 });
  });

  it('tolerates undefined metadata', () => {
    expect(liftConfidence(undefined)).toEqual({});
  });

  it('tolerates a missing typesafe key', () => {
    expect(liftConfidence({})).toEqual({});
  });

  it('drops non-number values instead of throwing', () => {
    const meta = { typesafe: { confidence: { type: 0.9, Priority: 'high', Risk: null, Source: undefined } } };
    expect(liftConfidence(meta)).toEqual({ type: 0.9 });
  });

  it('tolerates a non-object confidence value', () => {
    expect(liftConfidence({ typesafe: { confidence: 'nope' } })).toEqual({});
  });
});
