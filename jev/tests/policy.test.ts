// Pins the floors in `src/policy.ts`. Lowering any of these needs this test
// changed and a reason given in the commit message, that is the point of
// the test, not an oversight to work around.

import { describe, expect, it } from 'vitest';
import {
  AREA_THRESHOLD,
  FIELD_THRESHOLD,
  ROUTE_THRESHOLD,
  SENSITIVE_THRESHOLD,
  TRIVIAL_THRESHOLD,
  area,
  fields,
  optionTable,
  reviewRoute,
  routes,
  typeField,
} from '../src/policy.ts';

describe('thresholds', () => {
  it('never drops below the floors', () => {
    expect(FIELD_THRESHOLD).toBeGreaterThanOrEqual(0.9);
    expect(ROUTE_THRESHOLD).toBeGreaterThanOrEqual(0.9);
    expect(AREA_THRESHOLD).toBeGreaterThanOrEqual(0.85);
    expect(SENSITIVE_THRESHOLD).toBeGreaterThanOrEqual(0.9);
    expect(TRIVIAL_THRESHOLD).toBeGreaterThanOrEqual(0.95);
  });

  it('every route in the routes table uses ROUTE_THRESHOLD', () => {
    for (const r of Object.values(routes)) expect(r.threshold).toBe(ROUTE_THRESHOLD);
  });

  it('the area question uses AREA_THRESHOLD', () => {
    expect(area.threshold).toBe(AREA_THRESHOLD);
  });

  it('the sensitive and trivial review-route questions use their floors', () => {
    expect(reviewRoute.sensitive.threshold).toBe(SENSITIVE_THRESHOLD);
    expect(reviewRoute.trivial.threshold).toBe(TRIVIAL_THRESHOLD);
  });
});

describe('optionTable', () => {
  it('matches the org issue type and field vocabulary exactly', () => {
    expect(optionTable()).toEqual({
      [typeField.name]: ['Bug', 'Feature', 'Improvement', 'Task', 'Chore', 'Spike', 'Epic', 'Initiative'],
      Priority: ['Urgent', 'High', 'Medium', 'Low'],
      Effort: ['High', 'Medium', 'Low'],
      Risk: ['Low', 'Medium', 'High', 'Critical'],
      Source: ['Customer', 'Internal', 'Bot', 'Incident', 'Audit'],
    });
  });

  it('has exactly the four field names (Type is separate), in the order the fields table declares', () => {
    expect(fields.map((f) => f.name)).toEqual(['Priority', 'Effort', 'Risk', 'Source']);
  });
});
