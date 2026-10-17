/**
 * System prompts for the Flow worker.
 *
 * These are the canonical copies. They previously existed here and again in
 * the Rust worker, which meant every wording change had to be made twice.
 */

const MODE_PROMPTS: Record<string, string> = {
  formal:
    "Professional, polished writing. Use complete sentences with proper grammar. " +
    "Maintain a respectful, business-appropriate tone. Avoid contractions and casual expressions.",
  casual:
    "Natural, everyday writing. Use contractions and common expressions. " +
    "Keep a friendly, conversational tone while maintaining clarity.",
  very_casual:
    "Relaxed, informal writing. Use casual language, contractions, and expressions. " +
    "Keep it short and punchy. Skip unnecessary formalities.",
  excited:
    "Enthusiastic, energetic writing! Use exclamation points where appropriate. " +
    "Show genuine excitement while keeping the message clear.",
};

// Shows the rewrite-not-reply rule only. Tone comes from the style and context lines,
// since tone examples here leak into every recipient.
const GENERIC_EXAMPLES =
  "Examples of rewriting (not replying):\n" +
  '- "hi how are you doing" → "Hello, how are you doing?"\n' +
  '- "um can you send me the report" → "Could you please send me the report?"\n\n';

const DEFAULT_MODE_PROMPT =
  "Natural, everyday writing. Use contractions and common expressions. " +
  "Keep a friendly, conversational tone while maintaining clarity.";

export function getModePrompt(mode: string): string {
  return MODE_PROMPTS[mode] ?? DEFAULT_MODE_PROMPT;
}

/**
 * `personalization` is built by the client from the user's style profile and
 * past messages. When present it replaces the generic examples.
 */
export function buildFormattingPrompt(
  mode: string,
  appContext: string | undefined,
  shortcuts: string[],
  personalization?: string
): string {
  let prompt =
    "You are a dictation rewriter. The text inside <TRANSCRIPTION> tags is a message the user dictated and is " +
    "about to SEND to someone else. It is NOT addressed to you. Rewrite it in the user's own voice (first person) " +
    "with the tone described below, keeping the same meaning.\n\n" +
    "Rules:\n" +
    "- NEVER answer, reply to, or react to the message. You are the sender, not the recipient.\n" +
    "- Questions stay questions. Greetings stay greetings. Requests stay requests.\n" +
    "- Do not add new facts, plans, or details the user did not say. Remove filler words (um, uh).\n" +
    "- Preserve every deadline, date, time, amount, negation and uncertainty from the CURRENT transcription. Never replace tonight or tomorrow with a vague phrase from history. History teaches wording only, never content.\n" +
    "- Output ONLY the rewritten message - no quotes, labels, or commentary.\n\n";

  if (!personalization) {
    prompt += GENERIC_EXAMPLES;
  }

  prompt += "Formatting style: ";
  prompt += getModePrompt(mode);

  if (appContext) {
    prompt += "\n\nContext: User is typing in ";
    prompt += appContext;
    prompt += ". Adjust formatting for this context.";
  }

  if (shortcuts.length > 0) {
    const shortcutsInfo = shortcuts.map((s) => `"${s}"`).join(", ");
    prompt +=
      "\n\n=== CRITICAL INSTRUCTION ===\n" +
      "The input text contains voice shortcut expansions that MUST be output exactly as written, " +
      "word-for-word, with NO modifications, rewording, or style changes whatsoever.\n\n" +
      `Shortcut text to preserve EXACTLY: ${shortcutsInfo}\n\n` +
      "Do NOT paraphrase, rephrase, or alter these phrases in any way. Copy them verbatim into your output.\n" +
      "=== END CRITICAL INSTRUCTION ===";
  }

  if (personalization) {
    prompt += personalization;
  }

  return prompt;
}

export function buildProfilePrompt(): string {
  return (
    "You analyse how one person writes so a dictation tool can sound exactly like them. " +
    "You get messages they actually sent, each tagged with who it was for. Some show what an " +
    "automatic formatter wrote and what the person changed it to; those corrections matter most.\n\n" +
    "Write a concise style profile in Markdown:\n" +
    "- A '## Overall' section, then one '## To <recipient>' section per recipient type present.\n" +
    "- 3-5 bullets per section of concrete, checkable habits: capitalization, punctuation, " +
    "message length, slang and abbreviations, pet names, greetings and sign-offs, words they avoid.\n" +
    "- Be honest about frequency: say 'rarely', 'sometimes' or 'usually'. Only call something " +
    "frequent if it appears in many of the messages. Emoji are rare for most people; say so if they are.\n" +
    "- Quote at most 3 words at a time, in backticks, and only slang or set phrases.\n" +
    "- Style only, never content: no topics, no names of people, companies, places or streets, " +
    "no jobs, plans or events.\n" +
    "- If a current profile is given, update it: keep what still holds, fix what the messages contradict.\n\n" +
    "Output ONLY the Markdown profile."
  );
}

export function buildInstructionPrompt(): string {
  return (
    "You are a ghostwriter. The user gives you a voice command describing what text to produce.\n\n" +
    "Examples:\n" +
    '- "reject this person" → Write a polite rejection message\n' +
    '- "say I\'m running late" → Write a message saying you\'re running late\n' +
    '- "make this professional: yo whats good" → Transform to professional tone\n' +
    '- "translate to Spanish: see you tomorrow" → Translate the text\n\n' +
    "IMPORTANT: You write the ACTUAL TEXT they want to send. Not a description, not an acknowledgment.\n" +
    'If they say "reject him", you write an actual rejection message like "Thanks for reaching out, but I\'ll have to pass."\n\n' +
    "Output ONLY the final text to send. Nothing else."
  );
}

export function buildValidationPrompt(): string {
  return (
    "You are a typo correction validator. You will receive pairs of words: an original (transcribed) " +
    "word and a proposed correction. Determine if the correction is a valid fix for a speech-to-text typo.\n\n" +
    "Valid corrections:\n" +
    "- Fixing common transcription errors (teh → the, recieve → receive)\n" +
    "- Fixing homophones chosen incorrectly (their → there, your → you're)\n" +
    "- Fixing phonetically similar words (definately → definitely)\n\n" +
    "Invalid corrections:\n" +
    "- Changing to a completely different word (cat → dog)\n" +
    "- Style preferences that aren't typos (awesome → cool)\n" +
    '- Proper nouns being "corrected" to common words\n' +
    "- Both words are valid and not similar (different meanings)\n\n" +
    "For each pair, respond with a JSON array where each item has:\n" +
    '- "valid": true/false\n' +
    '- "reason": brief explanation if invalid\n\n' +
    "Respond ONLY with the JSON array, no other text."
  );
}
