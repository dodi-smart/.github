// Keep a request inside the model's window without asking the model to count.
//
// The window is 64k tokens per request, and the state plus the longest single
// question must fit in 32k. Tokens are estimated at four characters each,
// which over-counts English and under-counts code, so the budget below leaves
// room on both sides. When the state is too big the largest free-text field is
// cut, never the structured fields, and the caller records `truncated: true`
// so a decision made on a partial diff is never mistaken for one made on the
// whole.

import { createHash } from 'node:crypto';

/** Characters the state may occupy after the questions have been reserved. */
export const STATE_CHAR_BUDGET = 96_000;

export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

export function hashState(state: unknown): string {
  return 'sha256:' + createHash('sha256').update(JSON.stringify(state)).digest('hex');
}

/**
 * Cut the named text fields, largest first, until the serialised state fits.
 * Returns a copy; the input is never changed.
 */
export function fitState<T extends Record<string, unknown>>(
  state: T,
  textFields: readonly (keyof T & string)[],
  budget = STATE_CHAR_BUDGET,
): { state: T; truncated: boolean } {
  let out: Record<string, unknown> = { ...state };
  let truncated = false;
  let size = JSON.stringify(out).length;
  if (size <= budget) return { state: out as T, truncated };

  const order = [...textFields]
    .filter((k) => typeof out[k] === 'string')
    .sort((a, b) => (out[b] as string).length - (out[a] as string).length);

  for (const key of order) {
    if (size <= budget) break;
    const text = out[key] as string;
    const over = size - budget;
    const keep = Math.max(0, text.length - over - 64);
    out = { ...out, [key]: text.slice(0, keep) + '\n[cut: state exceeded the model window]' };
    truncated = true;
    size = JSON.stringify(out).length;
  }
  return { state: out as T, truncated };
}
