// Reports coverage and accuracy of the classifier against a labeled set,
// across a range of confidence thresholds. It is an operator tool, run by
// hand against real (already-anonymised) decisions or live against the
// gateway; it is not part of the test suite and not run in CI.
//
// Usage (from the package root):
//   node scripts/eval.ts --input labeled.jsonl                      # live, needs AI_GATEWAY_API_KEY
//   node scripts/eval.ts --input labeled.jsonl --from-decisions dir  # replay recorded decisions
//
// Each line of the input file is one labeled item:
//   { "task": "triage", "state": { ... }, "expected": { "Type": "Bug", "Priority": "High", "areas": ["area:ledger"], "route": "agent" } }
//
// `--from-decisions <dir>` reads `<dir>/0.json`, `<dir>/1.json`, ..., one
// decisions record per line of the input file, in the same order, instead
// of calling the gateway.

import { readFileSync } from 'node:fs';
import { gatewayTransport } from '../src/gateway.ts';
import { AREA_THRESHOLD } from '../src/policy.ts';
import { run } from '../src/cli.ts';
import type { Decisions, Task } from '../src/types.ts';

export type EvalExpected = {
  Type?: string;
  Priority?: string;
  Effort?: string;
  Risk?: string;
  Source?: string;
  areas?: string[];
  route?: 'agent' | 'skip';
};

export type EvalItem = { task: Task; state: unknown; expected: EvalExpected };

const THRESHOLDS = Array.from({ length: 10 }, (_, i) => Math.round((0.5 + i * 0.05) * 100) / 100);
const CHOICE_FIELDS = ['Type', 'Priority', 'Effort', 'Risk', 'Source'] as const;

function fieldOf(d: Decisions, name: (typeof CHOICE_FIELDS)[number]): { value: string; confidence: number } | undefined {
  if (name === 'Type') return d.type ? { value: d.type.value, confidence: d.type.confidence } : undefined;
  const f = d.fields.find((x) => x.name === name);
  return f ? { value: f.value, confidence: f.confidence } : undefined;
}

/** One line of the table, per confidence threshold, per field. */
type FieldRow = { field: string; threshold: number; coverage: number; accuracy: number; covered: number; total: number };

/** Coverage and accuracy of each choice field at every threshold, plus area label precision/recall and route accuracy. Pure: no I/O, safe to unit test. */
export function computeTable(items: EvalItem[], decisions: Decisions[]): string {
  if (items.length !== decisions.length) throw new Error(`items (${items.length}) and decisions (${decisions.length}) must be the same length`);

  const rows: FieldRow[] = [];
  for (const field of CHOICE_FIELDS) {
    const labeled = items
      .map((item, i) => ({ expected: item.expected[field], got: fieldOf(decisions[i]!, field) }))
      .filter((x): x is { expected: string; got: { value: string; confidence: number } | undefined } => x.expected !== undefined);
    if (!labeled.length) continue;
    for (const t of THRESHOLDS) {
      const covered = labeled.filter((x) => x.got !== undefined && x.got.confidence >= t);
      const correct = covered.filter((x) => x.got!.value === x.expected);
      rows.push({
        field,
        threshold: t,
        coverage: covered.length / labeled.length,
        accuracy: covered.length ? correct.length / covered.length : 0,
        covered: covered.length,
        total: labeled.length,
      });
    }
  }

  let areaTP = 0;
  let areaFP = 0;
  let areaFN = 0;
  let routeCorrect = 0;
  let routeTotal = 0;
  items.forEach((item, i) => {
    const d = decisions[i]!;
    if (item.expected.areas) {
      const got = new Set(d.labels.add.filter((l) => l.startsWith('area:')));
      const want = new Set(item.expected.areas);
      for (const a of got) {
        if (want.has(a)) areaTP++;
        else areaFP++;
      }
      for (const a of want) if (!got.has(a)) areaFN++;
    }
    if (item.expected.route) {
      routeTotal++;
      if (d.route === item.expected.route) routeCorrect++;
    }
  });

  return formatTable(rows, { areaTP, areaFP, areaFN, routeCorrect, routeTotal });
}

function pct(n: number): string {
  return `${(n * 100).toFixed(0)}%`;
}

function formatTable(
  rows: FieldRow[],
  summary: { areaTP: number; areaFP: number; areaFN: number; routeCorrect: number; routeTotal: number },
): string {
  const lines: string[] = [];
  for (const field of CHOICE_FIELDS) {
    const forField = rows.filter((r) => r.field === field);
    if (!forField.length) continue;
    lines.push(`${field} (n=${forField[0]!.total})`, 'threshold  coverage  accuracy  covered');
    for (const r of forField) {
      lines.push(`${r.threshold.toFixed(2)}       ${pct(r.coverage).padEnd(8)}  ${pct(r.accuracy).padEnd(8)}  ${r.covered}/${r.total}`);
    }
    lines.push('');
  }

  const { areaTP, areaFP, areaFN, routeCorrect, routeTotal } = summary;
  const precision = areaTP + areaFP ? areaTP / (areaTP + areaFP) : 0;
  const recall = areaTP + areaFN ? areaTP / (areaTP + areaFN) : 0;
  lines.push(`area labels at AREA_THRESHOLD (${AREA_THRESHOLD}): precision ${pct(precision)}, recall ${pct(recall)} (tp=${areaTP} fp=${areaFP} fn=${areaFN})`);
  lines.push(`route: ${routeTotal ? pct(routeCorrect / routeTotal) : 'n/a'} (${routeCorrect}/${routeTotal})`);
  return lines.join('\n');
}

export function readJsonl(path: string): EvalItem[] {
  return readFileSync(path, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line) as EvalItem);
}

function parseArgs(argv: string[]): { input: string; fromDecisions?: string } {
  const opts: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i];
    if (k?.startsWith('--')) opts[k.slice(2)] = argv[i + 1] ?? '';
  }
  if (!opts.input) throw new Error('--input <labeled.jsonl> is required');
  return { input: opts.input, fromDecisions: opts['from-decisions'] };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const items = readJsonl(args.input);

  let decisions: Decisions[];
  if (args.fromDecisions) {
    decisions = items.map((_, i) => JSON.parse(readFileSync(`${args.fromDecisions}/${i}.json`, 'utf8')) as Decisions);
  } else {
    const apiKey = process.env.AI_GATEWAY_API_KEY;
    if (!apiKey) throw new Error('AI_GATEWAY_API_KEY is not set, and --from-decisions was not given');
    const transport = gatewayTransport(apiKey);
    decisions = [];
    for (const item of items) decisions.push(await run(item.task, item.state, 'active', transport));
  }

  console.log(computeTable(items, decisions));
}

if (process.argv[1] && /eval\.ts$/.test(process.argv[1])) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
