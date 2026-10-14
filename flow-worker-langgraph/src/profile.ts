/**
 * Style profile builder.
 *
 * Turns a sample of the user's sent messages into a short Markdown profile the
 * client stores and sends back with each formatting request.
 */

import type { Env, StyleProfileExample } from "./types.js";
import { completeChat } from "./llm.js";
import { buildProfilePrompt } from "./prompts.js";

const PROFILE_OPTIONS = { maxTokens: 900, temperature: 0.2 };

function describe(example: StyleProfileExample): string {
  if (example.formatterWrote) {
    return `[to ${example.category}] formatter wrote: "${example.formatterWrote}" → they sent: "${example.sent}"`;
  }
  return `[to ${example.category}] "${example.sent}"`;
}

export async function buildStyleProfile(
  env: Env,
  examples: StyleProfileExample[],
  currentProfile?: string
): Promise<string> {
  let user = "";
  if (currentProfile) {
    user += `Current profile:\n${currentProfile}\n\n`;
  }
  user += `Messages:\n${examples.map(describe).join("\n")}`;

  return completeChat(env, buildProfilePrompt(), user, PROFILE_OPTIONS);
}
