/**
 * Flow Worker - Cloudflare Worker entry point using Hono.
 *
 * Endpoints:
 * - GET  /health            - liveness probe
 * - POST /                  - transcription, then formatting or command execution
 * - POST /validate-corrections - judge learned correction pairs
 */

import { Hono } from "hono";
import type {
  Env,
  CombinedResponse,
  ValidateCorrectionsResponse,
} from "./types.js";
import { UpstreamError } from "./http.js";
import { runFlowGraph } from "./graph.js";
import { validateCorrections } from "./validation.js";
import {
  parseCorrectionsRequest,
  parseTranscriptionRequest,
} from "./requests.js";

const app = new Hono<{ Bindings: Env }>();

/**
 * A provider failure is reported as a bad gateway rather than an internal
 * error, so a caller can tell "the upstream is down" from "this worker is
 * broken" and retry accordingly.
 */
function statusForGraphError(message: string): 500 | 502 {
  const fromProvider =
    message.startsWith("OpenRouter error") || message.startsWith("Baseten error");
  return fromProvider ? 502 : 500;
}

app.get("/health", (c) => c.json({ status: "ok" }));

/**
 * POST / - transcribe audio, then either format it or execute the command.
 *
 * Request body:
 * {
 *   "whisper_input": {
 *     "audio": { "audio_b64": "..." },
 *     "whisper_params": { "audio_language": "en", "prompt": "optional hint" }
 *   },
 *   "completion": {
 *     "mode": "casual",
 *     "app_context": "optional context",
 *     "shortcuts_triggered": [],
 *     "voice_instruction": "optional override"
 *   }
 * }
 *
 * Response:
 * { "transcription": "...", "text": "...", "command": "upper?", "action": "clear?" }
 */
app.post("/", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid JSON" }, 400);
  }

  const parsed = parseTranscriptionRequest(body);
  if (!parsed.ok) {
    return c.json({ error: parsed.error }, 400);
  }

  const result = await runFlowGraph({ ...parsed.value, env: c.env });

  if (result.error) {
    console.error(`graph failed: ${result.error}`);
    return c.json({ error: result.error }, statusForGraphError(result.error));
  }

  const response: CombinedResponse = {
    transcription: result.transcription ?? "",
    text: result.formattedText ?? "",
    command: result.command,
    action: result.action,
  };

  return c.json(response);
});

/**
 * POST /validate-corrections
 *
 * Request body:  { "corrections": [{ "original": "...", "corrected": "..." }] }
 * Response:      { "results": [{ "original", "corrected", "valid", "reason" }] }
 */
app.post("/validate-corrections", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid JSON" }, 400);
  }

  const parsed = parseCorrectionsRequest(body);
  if (!parsed.ok) {
    return c.json({ error: parsed.error }, 400);
  }

  try {
    const results = await validateCorrections(c.env, parsed.value);
    const response: ValidateCorrectionsResponse = { results };
    return c.json(response);
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    console.error(`validation failed: ${message}`);
    return c.json({ error: message }, err instanceof UpstreamError ? 502 : 500);
  }
});

app.all("*", (c) => c.json({ error: "method not allowed" }, 405));

// Anything that escapes a handler still returns the standard error shape.
app.onError((err, c) => {
  console.error(`unhandled: ${err.message}`);
  return c.json({ error: "internal error" }, 500);
});

export default app;
