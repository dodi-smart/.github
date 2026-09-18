// Turn a decisions record into the three things a workflow reads: a block for
// the agent prompt, a job-summary table, and `$GITHUB_OUTPUT` lines.

import { randomBytes } from 'node:crypto';
import type { Decisions } from './types.ts';

/** The prompt block. Stable in shape whether or not the model ran, so the agent prompt never changes form. */
export function promptBlock(d: Decisions): string {
  if (d.notEvaluated) return `Not evaluated: ${d.notEvaluated}. Classify everything yourself, as before.`;
  if (d.task === 'triage') return triagePromptBlock(d);
  if (d.task === 'review-route') return reviewRoutePromptBlock(d);
  return d.extra.note ? String(d.extra.note) : '';
}

function triagePromptBlock(d: Decisions): string {
  const set: string[] = [];
  const open: string[] = [];
  if (d.type) (d.type.act ? set : open).push(`Type=${d.type.value} (${d.type.confidence})`);
  for (const f of d.fields) {
    if (f.act) set.push(`${f.name}=${f.value} (${f.confidence})`);
    else if (f.suggest) open.push(`${f.name}: consider ${f.value} (${f.confidence}), the classifier leans that way but is not sure`);
    else open.push(`${f.name}: leaning ${f.value} (${f.confidence})`);
  }
  for (const l of d.labels.add) set.push(l);
  const lines: string[] = [];
  lines.push(
    set.length
      ? `Already set by the job, do not set again unless the issue text contradicts it: ${set.join(', ')}.`
      : 'Nothing was set by the job.',
  );
  if (open.length) lines.push(`Still open, decide these yourself: ${open.join('; ')}.`);
  if (d.mode === 'shadow') lines.push('The classifier ran in shadow mode, so nothing above was written. Set every field yourself.');
  return lines.join('\n');
}

function reviewRoutePromptBlock(d: Decisions): string {
  const lines: string[] = [];
  if (d.extra.descriptionMismatch) {
    lines.push(
      `Pre-read: the description does not describe this diff (match ${d.extra.descriptionMatchesDiff}). Lead the verdict with what the diff actually does.`,
    );
  } else {
    lines.push(`Pre-read: the description matches the diff (match ${d.extra.descriptionMatchesDiff}).`);
  }
  if (Number(d.extra.sensitive) >= 0.5) lines.push(`Pre-read: the diff touches something sensitive (${d.extra.sensitive}). Review it at that depth.`);
  return lines.join('\n');
}

/** Markdown for `$GITHUB_STEP_SUMMARY`. */
export function summary(d: Decisions): string {
  const rows: string[] = [];
  rows.push(`### jev ${d.task} (${d.mode}${d.truncated ? ', state truncated' : ''})`, '');
  if (d.notEvaluated) {
    rows.push(`Not evaluated: ${d.notEvaluated}`);
    return rows.join('\n') + '\n';
  }
  rows.push(`Model \`${d.model}\`, policy ${d.policyVersion}, ${d.latencyMs} ms. Route: **${d.route}**${d.routeReason ? ` (${d.routeReason})` : ''}.`, '');
  if (d.type || d.fields.length) {
    rows.push('| Field | Value | Confidence | Written |', '|---|---|---|---|');
    if (d.type) rows.push(`| Type | ${d.type.value} | ${d.type.confidence} | ${d.type.act ? 'yes' : 'no'} |`);
    for (const f of d.fields) rows.push(`| ${f.name} | ${f.value} | ${f.confidence} | ${f.act ? 'yes' : f.suggest ? 'suggested' : 'no'} |`);
    rows.push('');
  }
  if (d.labels.add.length) rows.push(`Labels added: ${d.labels.add.join(', ')}`, '');
  const extras = Object.entries(d.extra).filter(([k]) => k !== 'skipComment' && k !== 'note');
  if (extras.length) rows.push(extras.map(([k, v]) => `${k}: ${v}`).join(', '), '');
  if (d.extra.note) rows.push(String(d.extra.note), '');
  return rows.join('\n') + '\n';
}

/** Lines for `$GITHUB_OUTPUT`. Multi-line values use a random delimiter, since issue text can contain any fixed one. */
export function githubOutput(d: Decisions): string {
  const single = (k: string, v: string | number | boolean) => `${k}=${String(v).replace(/\r?\n/g, ' ')}`;
  const multi = (k: string, v: string) => {
    const eof = 'EOF_' + randomBytes(8).toString('hex');
    return `${k}<<${eof}\n${v}\n${eof}`;
  };
  const lines = [
    single('ran', !d.notEvaluated),
    single('route', d.route),
    single('route-reason', d.routeReason),
    single('type', d.type?.act ? d.type.value : ''),
    multi('fields', d.fields.filter((f) => f.act).map((f) => `${f.name}=${f.value}`).join('\n')),
    single('add-labels', d.labels.add.join(' ')),
    single('remove-labels', d.labels.remove.join(' ')),
    single('level', d.extra.level ?? ''),
    single('reason', d.extra.reason ?? ''),
    multi('skip-comment', String(d.extra.skipComment ?? '')),
    multi('prompt-block', promptBlock(d)),
    multi('note', String(d.extra.note ?? '')),
  ];
  return lines.join('\n') + '\n';
}
