// The shapes every task and the renderer agree on. Nothing here imports the
// SDK, so a test can build any of these by hand.

export type Task = 'triage' | 'review-route' | 'review-check';
export type Mode = 'active' | 'shadow';
export type Route = 'agent' | 'skip';

/** A question exactly as the evaluation model takes it. */
export type Question =
  | { type: 'boolean'; instructions: unknown; criteria?: { true?: unknown; false?: unknown } }
  | { type: 'choice'; instructions: unknown; criteria: Record<string, unknown> }
  | { type: 'score'; instructions: unknown; criteria: readonly unknown[] };

/** An answer exactly as the evaluation model returns it. */
export type Answer =
  | { type: 'boolean'; probability: number }
  | { type: 'choice'; choice: string; probabilities?: Record<string, number> }
  | { type: 'score'; score: number; probabilities?: Record<string, number> };

/** What the transport hands back: answers plus the provider's confidence per question. */
export type Evaluation = {
  answers: Record<string, Answer>;
  /** `confidence` from the provider metadata, keyed by question id, when the provider sent it. */
  confidence: Record<string, number>;
  usage: { inputTokens?: number; outputTokens?: number };
  modelId: string;
  latencyMs: number;
};

export type Transport = (state: unknown, questions: Record<string, Question>) => Promise<Evaluation>;

export type FieldDecision = {
  name: string;
  value: string;
  /** The provider's confidence when it sent one, else the winning option's probability. */
  confidence: number;
  act: boolean;
  /** Present when the value is worth telling the agent even though it will not be written. */
  suggest?: true;
};

export type Decisions = {
  task: Task;
  mode: Mode;
  model: string;
  policyVersion: string;
  stateHash: string;
  truncated: boolean;
  latencyMs: number;
  route: Route;
  routeReason: string;
  fields: FieldDecision[];
  type: { value: string; confidence: number; act: boolean } | null;
  labels: { add: string[]; remove: string[] };
  /** Task-specific numbers the workflow reads, e.g. review depth. */
  extra: Record<string, string | number | boolean>;
  /** Raw answers and confidences, for the calibration set. */
  answers: Record<string, Answer & { confidence?: number }>;
  /** Present when the model was not called; the reason is human-readable. */
  notEvaluated?: string;
};
