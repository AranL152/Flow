/**
 * Workers AI chat client.
 *
 * Formatting, ghostwriting, correction validation and profile building share
 * this one call. The model can be overridden with the CHAT_MODEL var.
 */

import { UpstreamError } from "./http.js";
import type { Env } from "./types.js";

const DEFAULT_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

export interface ChatOptions {
  maxTokens: number;
  temperature: number;
}

/** Send a system/user pair and return the assistant's text. */
export async function completeChat(
  env: Env,
  system: string,
  user: string,
  options: ChatOptions
): Promise<string> {
  const model = (env.CHAT_MODEL || DEFAULT_MODEL) as typeof DEFAULT_MODEL;
  const started = Date.now();

  let result: { response?: unknown };
  try {
    result = (await env.AI.run(model, {
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      max_tokens: options.maxTokens,
      temperature: options.temperature,
    })) as { response?: unknown };
  } catch (err) {
    throw new UpstreamError("Workers AI", 502, err instanceof Error ? err.message : String(err));
  }
  console.log(`chat ${Date.now() - started}ms model=${model}`);

  // Workers AI parses JSON-looking output into an object
  const response = result.response;
  const content = (typeof response === "string" ? response : JSON.stringify(response ?? ""))
    .trim();
  if (!content || content === '""') {
    throw new UpstreamError("Workers AI", 0, "no completion returned");
  }

  return content;
}
