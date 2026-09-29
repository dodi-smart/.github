import { describe, expect, it } from 'vitest';
import { githubOutput, promptBlock } from '../src/render.ts';
import { emptyDecisions } from '../src/common.ts';
import type { Decisions } from '../src/types.ts';

function triageDecisions(overrides: Partial<Decisions> = {}): Decisions {
  const d = emptyDecisions('triage', 'active', { title: 'x' }, false);
  return { ...d, ...overrides };
}

describe('promptBlock', () => {
  it('lists set fields and open fields when the classifier ran', () => {
    const d = triageDecisions({
      type: { value: 'Bug', confidence: 0.95, act: true },
      fields: [
        { name: 'Priority', value: 'High', confidence: 0.92, act: true },
        { name: 'Risk', value: 'High', confidence: 0.7, act: false, suggest: true },
        { name: 'Source', value: 'Customer', confidence: 0.5, act: false },
      ],
      labels: { add: ['area:ledger'], remove: [] },
    });
    const text = promptBlock(d);
    expect(text).toContain('Already set by the job');
    expect(text).toContain('Type=Bug (0.95)');
    expect(text).toContain('Priority=High (0.92)');
    expect(text).toContain('area:ledger');
    expect(text).toContain('Still open, decide these yourself');
    expect(text).toContain('consider High (0.7)');
    expect(text).toContain('leaning Customer (0.5)');
  });

  it('says everything is not evaluated when notEvaluated is set', () => {
    const d = triageDecisions({ notEvaluated: 'AI_GATEWAY_API_KEY is not set' });
    const text = promptBlock(d);
    expect(text).toBe('Not evaluated: AI_GATEWAY_API_KEY is not set. Classify everything yourself, as before.');
  });

  it('tells the agent to set every field itself in shadow mode', () => {
    const d = triageDecisions({
      mode: 'shadow',
      type: { value: 'Bug', confidence: 0.95, act: false },
      fields: [{ name: 'Priority', value: 'High', confidence: 0.92, act: false }],
    });
    const text = promptBlock(d);
    expect(text).toContain('Nothing was set by the job');
    expect(text).toContain('shadow mode');
    expect(text).toContain('Set every field yourself');
  });
});

/** Parses `key=value` and `key<<EOF_x\n...\nEOF_x` lines back into a map, the way a shell reading $GITHUB_OUTPUT would. */
function parseGithubOutput(text: string): Record<string, string> {
  const lines = text.split('\n');
  const out: Record<string, string> = {};
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line === undefined || line === '') continue;
    const heredoc = /^([^=<]+)<<(\S+)$/.exec(line);
    if (heredoc) {
      const [, key, delimiter] = heredoc;
      const body: string[] = [];
      i++;
      while (i < lines.length && lines[i] !== delimiter) {
        body.push(lines[i]!);
        i++;
      }
      out[key!] = body.join('\n');
      continue;
    }
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    out[line.slice(0, eq)] = line.slice(eq + 1);
  }
  return out;
}

describe('githubOutput', () => {
  it('round-trips through the heredoc parser, including newlines and literal EOF-looking text', () => {
    const tricky = 'Priority=High\n__EOF__ is not a real delimiter\nEOF\nneither is this';
    const d = triageDecisions({
      fields: [{ name: 'Priority', value: tricky, confidence: 0.9, act: true }],
    });
    const parsed = parseGithubOutput(githubOutput(d));
    expect(parsed.fields).toBe(`Priority=${tricky}`);
    expect(parsed.ran).toBe('true');
  });

  it('sets ran=false when notEvaluated is set', () => {
    const d = triageDecisions({ notEvaluated: 'boom' });
    const parsed = parseGithubOutput(githubOutput(d));
    expect(parsed.ran).toBe('false');
  });
});
