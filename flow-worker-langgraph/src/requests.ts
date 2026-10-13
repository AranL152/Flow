/**
 * Request parsing for the HTTP layer.
 *
 * The endpoints previously checked only that a few fields were present, so a
 * wrong type reached a provider as a malformed upstream call, and an oversized
 * payload was only rejected by the provider after being forwarded. Parsing
 * returns either a fully typed value or the first field that is wrong.
 */

import type { CorrectionPair } from "./types.js";

export type ParseResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

/** 16 MiB decoded; minutes of 16 kHz mono dictation sit well under this. */
export const MAX_AUDIO_BYTES = 16 * 1024 * 1024;
const MAX_MODE_CHARS = 64;
const MAX_APP_CONTEXT_CHARS = 200;
const MAX_INSTRUCTION_CHARS = 1000;
const MAX_SHORTCUTS = 50;
const MAX_SHORTCUT_CHARS = 500;
const MAX_CORRECTIONS = 100;
const MAX_CORRECTION_CHARS = 100;

export interface TranscriptionRequestInput {
  audioB64: string;
  audioLanguage: string;
  promptHint?: string;
  mode: string;
  appContext?: string;
  shortcutsTriggered: string[];
  voiceInstruction?: string;
}

function ok<T>(value: T): ParseResult<T> {
  return { ok: true, value };
}

function err(message: string): ParseResult<never> {
  return { ok: false, error: message };
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function optionalString(
  value: unknown,
  field: string,
  max: number
): ParseResult<string | undefined> {
  if (value === undefined || value === null) {
    return ok(undefined);
  }
  if (typeof value !== "string") {
    return err(`${field} must be a string`);
  }
  if (value.length > max) {
    return err(`${field} exceeds ${max} characters`);
  }
  return ok(value);
}

/**
 * Approximate the decoded size from the base64 length, so an oversized payload
 * is rejected without allocating the decoded buffer. The character set is left
 * unchecked on purpose: scanning tens of millions of characters to validate it
 * would cost more than the malformed call it would catch.
 */
function decodedSize(b64: string): number {
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.floor((b64.length * 3) / 4) - padding;
}

function parseShortcuts(value: unknown): ParseResult<string[]> {
  if (value === undefined || value === null) {
    return ok([]);
  }
  if (!Array.isArray(value)) {
    return err("completion.shortcuts_triggered must be an array");
  }
  if (value.length > MAX_SHORTCUTS) {
    return err(`completion.shortcuts_triggered holds at most ${MAX_SHORTCUTS} entries`);
  }

  const shortcuts: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") {
      return err("completion.shortcuts_triggered entries must be strings");
    }
    if (item.length > MAX_SHORTCUT_CHARS) {
      return err(`a shortcut exceeds ${MAX_SHORTCUT_CHARS} characters`);
    }
    shortcuts.push(item);
  }

  return ok(shortcuts);
}

export function parseTranscriptionRequest(
  body: unknown
): ParseResult<TranscriptionRequestInput> {
  const root = asRecord(body);
  if (!root) {
    return err("body must be a JSON object");
  }

  const whisperInput = asRecord(root.whisper_input);
  if (!whisperInput) {
    return err("missing whisper_input");
  }

  const audioB64 = asRecord(whisperInput.audio)?.audio_b64;
  if (typeof audioB64 !== "string" || audioB64.length === 0) {
    return err("missing whisper_input.audio.audio_b64");
  }
  if (decodedSize(audioB64) > MAX_AUDIO_BYTES) {
    return err(`audio exceeds the ${MAX_AUDIO_BYTES / (1024 * 1024)} MiB limit`);
  }

  const params = asRecord(whisperInput.whisper_params);
  const audioLanguage = params?.audio_language;
  if (typeof audioLanguage !== "string" || audioLanguage.length === 0) {
    return err("missing whisper_input.whisper_params.audio_language");
  }

  const promptHint = optionalString(
    params?.prompt,
    "whisper_params.prompt",
    MAX_INSTRUCTION_CHARS
  );
  if (!promptHint.ok) {
    return promptHint;
  }

  const completion = asRecord(root.completion);
  if (!completion) {
    return err("missing completion");
  }

  const mode = completion.mode;
  if (typeof mode !== "string" || mode.length === 0) {
    return err("missing completion.mode");
  }
  if (mode.length > MAX_MODE_CHARS) {
    return err(`completion.mode exceeds ${MAX_MODE_CHARS} characters`);
  }

  const appContext = optionalString(
    completion.app_context,
    "completion.app_context",
    MAX_APP_CONTEXT_CHARS
  );
  if (!appContext.ok) {
    return appContext;
  }

  const voiceInstruction = optionalString(
    completion.voice_instruction,
    "completion.voice_instruction",
    MAX_INSTRUCTION_CHARS
  );
  if (!voiceInstruction.ok) {
    return voiceInstruction;
  }

  const shortcuts = parseShortcuts(completion.shortcuts_triggered);
  if (!shortcuts.ok) {
    return shortcuts;
  }

  return ok({
    audioB64,
    audioLanguage,
    promptHint: promptHint.value,
    mode,
    appContext: appContext.value,
    shortcutsTriggered: shortcuts.value,
    voiceInstruction: voiceInstruction.value,
  });
}

export function parseCorrectionsRequest(
  body: unknown
): ParseResult<CorrectionPair[]> {
  const root = asRecord(body);
  if (!root) {
    return err("body must be a JSON object");
  }

  const list = root.corrections;
  if (!Array.isArray(list)) {
    return err("missing corrections array");
  }
  if (list.length > MAX_CORRECTIONS) {
    return err(`at most ${MAX_CORRECTIONS} corrections per request`);
  }

  const pairs: CorrectionPair[] = [];
  for (const entry of list) {
    const pair = asRecord(entry);
    const original = pair?.original;
    const corrected = pair?.corrected;

    if (typeof original !== "string" || typeof corrected !== "string") {
      return err("each correction needs original and corrected strings");
    }
    if (
      original.length > MAX_CORRECTION_CHARS ||
      corrected.length > MAX_CORRECTION_CHARS
    ) {
      return err(`correction words exceed ${MAX_CORRECTION_CHARS} characters`);
    }

    pairs.push({ original, corrected });
  }

  return ok(pairs);
}
