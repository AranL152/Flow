/**
 * LangGraph node functions for the Flow worker.
 *
 * Nodes stay thin: the provider calls live in the baseten and llm clients, so a
 * node is responsible only for picking the prompt and mapping a thrown
 * provider error onto the graph's error field.
 */

import type { FlowState } from "./types.js";
import { transcribeAudio } from "./baseten.js";
import { completeChat } from "./llm.js";
import { buildFormattingPrompt, buildInstructionPrompt } from "./prompts.js";

const WAKE_PHRASE = "hey flow";

const COMPLETION_OPTIONS = { maxTokens: 1000, temperature: 0.3 };

function toError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Node: transcribe audio with Whisper.
 */
export async function transcribeNode(state: FlowState): Promise<Partial<FlowState>> {
  const { env, audioB64, audioLanguage, promptHint } = state;

  // Seed the wake phrase into the decoder hint so Whisper spells it
  // consistently, which is what the detect step keys off.
  const prompt =
    promptHint && promptHint.length > 0 ? `Hey Flow. ${promptHint}` : "Hey Flow.";

  try {
    const transcription = await transcribeAudio(env.BASETEN_API_KEY, {
      audioB64,
      language: audioLanguage,
      prompt,
    });

    // Length only: transcriptions are user speech and do not belong in logs.
    console.log(`transcribed ${transcription.length} chars`);
    return { transcription };
  } catch (err) {
    return { error: toError(err) };
  }
}

/**
 * Node: detect the wake phrase and extract the utterance that follows.
 */
export function detectWakePhraseNode(state: FlowState): Partial<FlowState> {
  const { transcription, voiceInstruction } = state;

  // An explicit instruction from the client wins over phrase detection.
  if (voiceInstruction) {
    return { detectedCommand: voiceInstruction };
  }

  if (transcription?.toLowerCase().startsWith(WAKE_PHRASE)) {
    const rest = transcription.slice(WAKE_PHRASE.length).replace(/^[,\s]+/u, "");
    if (rest.length > 0) {
      return { detectedCommand: rest };
    }
  }

  return { detectedCommand: undefined };
}

/**
 * Routing: an utterance after the wake phrase goes to the instruction path,
 * everything else is plain dictation to format.
 */
export function routeByWakePhrase(state: FlowState): "format" | "instruct" {
  return state.detectedCommand ? "instruct" : "format";
}

/**
 * Node: reformat dictated text in the requested style.
 */
export async function formatNode(state: FlowState): Promise<Partial<FlowState>> {
  const { env, transcription, mode, appContext, shortcutsTriggered } = state;

  if (!transcription) {
    return { error: "No transcription to format" };
  }

  try {
    const formattedText = await completeChat(
      env.OPENROUTER_API_KEY,
      buildFormattingPrompt(mode, appContext, shortcutsTriggered),
      `<TRANSCRIPTION>\n${transcription}\n</TRANSCRIPTION>`,
      COMPLETION_OPTIONS
    );
    return { formattedText };
  } catch (err) {
    return { error: toError(err) };
  }
}

/**
 * Node: write the text the user asked for (ghostwriter mode).
 */
export async function instructNode(state: FlowState): Promise<Partial<FlowState>> {
  const { env, detectedCommand } = state;

  if (!detectedCommand) {
    return { error: "No voice command to process" };
  }

  try {
    const formattedText = await completeChat(
      env.OPENROUTER_API_KEY,
      buildInstructionPrompt(),
      detectedCommand,
      COMPLETION_OPTIONS
    );
    return { formattedText };
  } catch (err) {
    return { error: toError(err) };
  }
}
