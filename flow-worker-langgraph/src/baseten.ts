/**
 * Baseten Whisper client.
 *
 * Transcription gets a longer deadline than the chat calls because the request
 * carries the audio payload.
 */

import { UpstreamError, postJson } from "./http.js";
import type { Base10Request, Base10Response } from "./types.js";

const BASE10_API_URL =
  "https://model-232nj723.api.baseten.co/environments/production/predict";
const TIMEOUT_MS = 45_000;

export interface TranscribeParams {
  audioB64: string;
  language: string;
  /** Decoder hint; the wake phrase is seeded so Whisper recognises it */
  prompt: string;
}

/** Transcribe audio and return the text, throwing when nothing came back. */
export async function transcribeAudio(
  apiKey: string,
  { audioB64, language, prompt }: TranscribeParams
): Promise<string> {
  const request: Base10Request = {
    whisper_input: {
      audio: { audio_b64: audioB64 },
      whisper_params: {
        prompt,
        audio_language: language,
      },
    },
  };

  const response = await postJson<Base10Response>({
    service: "Baseten",
    url: BASE10_API_URL,
    headers: { Authorization: `Api-Key ${apiKey}` },
    body: request,
    timeoutMs: TIMEOUT_MS,
  });

  const fromSegments = response.segments?.map((s) => s.text).join("").trim();
  const transcription = fromSegments || response.text?.trim();

  if (!transcription) {
    throw new UpstreamError("Baseten", 0, "no transcription returned");
  }

  return transcription;
}
