/**
 * Workers AI Whisper client.
 */

import { UpstreamError } from "./http.js";
import type { Env } from "./types.js";

const MODEL = "@cf/openai/whisper-large-v3-turbo";

export interface TranscribeParams {
  audioB64: string;
  /** ISO code, or "auto" to let Whisper detect it */
  language: string;
  /** Decoder hint; the wake phrase is seeded so Whisper recognises it */
  prompt: string;
}

interface WhisperResult {
  text?: string;
  segments?: Array<{ text: string }>;
}

/** Transcribe audio and return the text, throwing when nothing came back. */
export async function transcribeAudio(
  env: Env,
  { audioB64, language, prompt }: TranscribeParams
): Promise<string> {
  const started = Date.now();

  let result: WhisperResult;
  try {
    result = (await env.AI.run(MODEL, {
      audio: audioB64,
      language: language && language !== "auto" ? language : undefined,
      initial_prompt: prompt,
    })) as WhisperResult;
  } catch (err) {
    throw new UpstreamError("Workers AI", 502, err instanceof Error ? err.message : String(err));
  }
  console.log(`whisper ${Date.now() - started}ms`);

  const fromSegments = result.segments?.map((s) => s.text).join("").trim();
  const transcription = fromSegments || result.text?.trim();

  if (!transcription) {
    throw new UpstreamError("Workers AI", 0, "no transcription returned");
  }

  return transcription;
}
