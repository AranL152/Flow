/**
 * Type definitions for the Flow worker.
 */

import type { CommandAction, ResolvedCommand } from "./commands.js";

export interface Env {
  AI: Ai;
  /** Optional Workers AI chat model override (see ai.ts for the default) */
  CHAT_MODEL?: string;
}

/**
 * Values handed to nodes through the graph's runtime config.
 *
 * Secrets travel here rather than in graph state, because state is what
 * LangGraph serialises, checkpoints and surfaces in traces.
 */
export interface FlowConfigurable {
  env: Env;
}

// ============ Request Types ============

export interface CombinedRequest {
  whisper_input: WhisperInput;
  completion: CompletionParams;
}

export interface WhisperInput {
  audio: AudioInput;
  whisper_params: WhisperParams;
}

export interface StyleProfileExample {
  /** Who the message was for, e.g. "partner" or "app:email" */
  category: string;
  sent: string;
  /** Set when the user rewrote the formatter's output into `sent` */
  formatterWrote?: string;
}

export interface AudioInput {
  audio_b64: string;
}

export interface WhisperParams {
  audio_language: string;
  prompt?: string;
}

export interface CompletionParams {
  mode: string;
  app_context?: string;
  shortcuts_triggered?: string[];
  voice_instruction?: string;
}

// ============ Response Types ============

export interface CombinedResponse {
  transcription: string;
  text: string;
  language?: string;
  /** Command id, set when the utterance was executed instead of sent to a model */
  command?: string;
  /** Side effect for the client to perform locally */
  action?: CommandAction;
}

// ============ Validation Types ============

export interface ValidateCorrectionsRequest {
  corrections: CorrectionPair[];
}

export interface CorrectionPair {
  original: string;
  corrected: string;
}

export interface CorrectionValidation {
  original: string;
  corrected: string;
  valid: boolean;
  reason?: string;
}

export interface ValidateCorrectionsResponse {
  results: CorrectionValidation[];
}

// ============ Graph State ============

export interface FlowState {
  // Input
  audioB64: string;
  audioLanguage: string;
  promptHint?: string;
  mode: string;
  appContext?: string;
  shortcutsTriggered: string[];
  voiceInstruction?: string;
  /** Typed text that replaces transcription */
  text?: string;
  personalization?: string;

  // Intermediate
  transcription?: string;
  /** Utterance following the wake phrase, if there was one */
  detectedCommand?: string;
  /** Set when the utterance matched a command the worker can run itself */
  resolvedCommand?: ResolvedCommand;

  // Output
  formattedText?: string;
  command?: string;
  action?: CommandAction;
  error?: string;
}
