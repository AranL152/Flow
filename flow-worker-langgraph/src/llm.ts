/**
 * OpenRouter chat client.
 *
 * The model list, provider routing and request shape live here so formatting,
 * ghostwriting and correction validation all share one definition instead of
 * repeating the same request block.
 */

import { UpstreamError, postJson } from "./http.js";
import type { OpenRouterRequest, OpenRouterResponse } from "./types.js";

const OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions";
const TIMEOUT_MS = 20_000;

const MODELS = [
  "meta-llama/llama-4-maverick:nitro",
  "openai/gpt-oss-120b:nitro",
  "openrouter/auto",
];

export interface ChatOptions {
  maxTokens: number;
  temperature: number;
}

/** Send a system/user pair and return the assistant's text. */
export async function completeChat(
  apiKey: string,
  system: string,
  user: string,
  options: ChatOptions
): Promise<string> {
  const request: OpenRouterRequest = {
    models: MODELS,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    max_tokens: options.maxTokens,
    temperature: options.temperature,
    provider: {
      allow_fallbacks: true,
      sort: {
        by: "throughput",
        partition: "none",
      },
    },
  };

  const response = await postJson<OpenRouterResponse>({
    service: "OpenRouter",
    url: OPENROUTER_API_URL,
    headers: { Authorization: `Bearer ${apiKey}` },
    body: request,
    timeoutMs: TIMEOUT_MS,
  });

  const content = response.choices?.[0]?.message?.content?.trim();
  if (!content) {
    throw new UpstreamError("OpenRouter", 0, "no completion returned");
  }

  return content;
}
