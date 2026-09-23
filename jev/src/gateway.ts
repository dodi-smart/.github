// The only module that imports the SDK. Everything else takes a `Transport`,
// so tests replace this file with a fixture player and never touch the network.
//
// The model is reached through the Vercel AI Gateway, never directly: the
// gateway holds the key, the budget and the request log, and it exposes the
// model as `typesafe-ai/jev` through the evaluation API. Confidence is not part
// of the SDK's answer shape; the provider sends it in `providerMetadata` under
// its own key, per question id, and this module lifts it out so the rest of the
// package never has to know where it came from.

import { experimental_evaluate as evaluate } from 'ai';
import { createGateway } from '@ai-sdk/gateway';
import { MODEL_ID } from './policy.ts';
import type { Answer, Evaluation, Question, Transport } from './types.ts';

export function gatewayTransport(apiKey: string): Transport {
  const gateway = createGateway({ apiKey });
  const model = gateway.evaluationModel(MODEL_ID);
  return async (state, questions) => {
    const started = Date.now();
    const result = await evaluate({
      model,
      state: state as never,
      questions: questions as never,
      maxRetries: 2,
      // The state is the org's own issues and diffs. Neither is training data.
      providerOptions: { typesafe: { zeroDataRetention: true, noTraining: true } },
    });
    return {
      answers: result.answers as unknown as Record<string, Answer>,
      confidence: liftConfidence(result.providerMetadata),
      usage: { inputTokens: result.usage.inputTokens, outputTokens: result.usage.outputTokens },
      modelId: result.response.modelId,
      latencyMs: Date.now() - started,
    };
  };
}

/** `providerMetadata.typesafe.confidence` keyed by question id, tolerant of absence. */
export function liftConfidence(meta: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  const typesafe = (meta as { typesafe?: { confidence?: unknown } } | undefined)?.typesafe;
  const conf = typesafe?.confidence;
  if (conf && typeof conf === 'object') {
    for (const [id, v] of Object.entries(conf as Record<string, unknown>)) {
      if (typeof v === 'number') out[id] = v;
    }
  }
  return out;
}

export type { Evaluation, Question };
