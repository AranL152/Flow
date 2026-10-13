/**
 * LangGraph node functions for the Flow worker.
 *
 * Nodes stay thin: the provider calls live in the baseten and llm clients, so a
 * node is responsible only for picking the prompt and mapping a thrown
 * provider error onto the graph's error field.
 */

import type { RunnableConfig } from "@langchain/core/runnables";
import type { Env, FlowConfigurable, FlowState } from "./types.js";
import { resolveCommand } from "./commands.js";
import { transcribeAudio } from "./baseten.js";
import { completeChat } from "./llm.js";
import { buildFormattingPrompt, buildInstructionPrompt } from "./prompts.js";

const WAKE_PHRASE = "hey flow";

const COMPLETION_OPTIONS = { maxTokens: 1000, temperature: 0.3 };

function toError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Pull the worker env out of the runtime config, where the secrets live. */
function requireEnv(config?: RunnableConfig): Env {
  const env = (config?.configurable as FlowConfigurable | undefined)?.env;
  if (!env) {
    throw new Error("worker env missing from graph config");
  }
  return env;
}

/**
 * Node: transcribe audio with Whisper.
 */
export async function transcribeNode(
  state: FlowState,
  config?: RunnableConfig
): Promise<Partial<FlowState>> {
  const { audioB64, audioLanguage, promptHint } = state;

  // Seed the wake phrase into the decoder hint so Whisper spells it
  // consistently, which is what the detect step keys off.
  const prompt =
    promptHint && promptHint.length > 0 ? `Hey Flow. ${promptHint}` : "Hey Flow.";

  try {
    const transcription = await transcribeAudio(requireEnv(config).BASETEN_API_KEY, {
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
 * Node: detect the wake phrase, extract the utterance that follows, and decide
 * whether it is a command the worker can run on its own.
 *
 * Resolution happens here rather than in the router so the phrase table is
 * consulted once per request.
 */
export function detectWakePhraseNode(state: FlowState): Partial<FlowState> {
  const { transcription, voiceInstruction } = state;

  // An explicit instruction from the client wins over phrase detection.
  const utterance = voiceInstruction ?? extractUtterance(transcription);

  if (!utterance) {
    return { detectedCommand: undefined, resolvedCommand: undefined };
  }

  return {
    detectedCommand: utterance,
    resolvedCommand: resolveCommand(utterance) ?? undefined,
  };
}

function extractUtterance(transcription?: string): string | undefined {
  if (!transcription?.toLowerCase().startsWith(WAKE_PHRASE)) {
    return undefined;
  }

  const rest = transcription.slice(WAKE_PHRASE.length).replace(/^[,\s]+/u, "");
  return rest.length > 0 ? rest : undefined;
}

/**
 * Routing: plain dictation is formatted, a recognised command is executed
 * locally, and anything else after the wake phrase goes to the model.
 */
export function routeByCommand(state: FlowState): "format" | "execute" | "instruct" {
  if (!state.detectedCommand) {
    return "format";
  }
  return state.resolvedCommand ? "execute" : "instruct";
}

/**
 * Routing: stop early when transcription failed, so the real provider error is
 * returned instead of being overwritten by a downstream node.
 */
export function routeAfterTranscribe(state: FlowState): "detect" | "end" {
  return state.error ? "end" : "detect";
}

/**
 * Node: run a recognised command. No model call and no network.
 */
export function executeNode(state: FlowState): Partial<FlowState> {
  const { resolvedCommand } = state;

  if (!resolvedCommand) {
    return { error: "No command to execute" };
  }

  console.log(`executed command ${resolvedCommand.id}`);

  return {
    formattedText: resolvedCommand.text,
    command: resolvedCommand.id,
    action: resolvedCommand.action,
  };
}

/**
 * Node: reformat dictated text in the requested style.
 */
export async function formatNode(
  state: FlowState,
  config?: RunnableConfig
): Promise<Partial<FlowState>> {
  const { transcription, mode, appContext, shortcutsTriggered } = state;

  if (!transcription) {
    return { error: "No transcription to format" };
  }

  try {
    const formattedText = await completeChat(
      requireEnv(config).OPENROUTER_API_KEY,
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
export async function instructNode(
  state: FlowState,
  config?: RunnableConfig
): Promise<Partial<FlowState>> {
  const { detectedCommand } = state;

  if (!detectedCommand) {
    return { error: "No voice command to process" };
  }

  try {
    const formattedText = await completeChat(
      requireEnv(config).OPENROUTER_API_KEY,
      buildInstructionPrompt(),
      detectedCommand,
      COMPLETION_OPTIONS
    );
    return { formattedText };
  } catch (err) {
    return { error: toError(err) };
  }
}
