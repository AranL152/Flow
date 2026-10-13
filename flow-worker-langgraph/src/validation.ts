/**
 * Correction validation.
 *
 * Judges whether a learned (original, corrected) pair is a real speech-to-text
 * typo fix rather than a word swap, so the client does not learn bad habits.
 */

import type { Env, CorrectionPair, CorrectionValidation } from "./types.js";
import { completeChat } from "./llm.js";
import { buildValidationPrompt } from "./prompts.js";

interface AIValidation {
  valid: boolean;
  reason?: string;
}

/** Validate correction pairs, keeping the pair order of the request. */
export async function validateCorrections(
  env: Env,
  corrections: CorrectionPair[]
): Promise<CorrectionValidation[]> {
  if (corrections.length === 0) {
    return [];
  }

  const content = await completeChat(
    env.OPENROUTER_API_KEY,
    buildValidationPrompt(),
    `Validate these corrections:\n${JSON.stringify(corrections)}`,
    { maxTokens: 500, temperature: 0.1 }
  );

  // Fail open: an unreadable judgement should not discard what the user taught
  // the app, so unparseable or mis-shaped output leaves the pairs valid.
  let aiResults: AIValidation[] = [];
  try {
    const parsed: unknown = JSON.parse(content);
    if (Array.isArray(parsed)) {
      aiResults = parsed as AIValidation[];
    } else {
      console.warn("validation response was not an array, failing open");
    }
  } catch {
    console.warn("validation response was not valid JSON, failing open");
  }

  return corrections.map((pair, i) => ({
    original: pair.original,
    corrected: pair.corrected,
    valid: aiResults[i]?.valid ?? true,
    reason: aiResults[i]?.reason,
  }));
}
