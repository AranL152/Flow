/**
 * Flow Worker - Cloudflare Worker entry point using Hono.
 *
 * Endpoints:
 * - GET  /health            - liveness probe
 * - POST /                  - transcription, then formatting or command execution
 * - POST /validate-corrections - judge learned correction pairs
 * - POST /style-profile     - summarise sent messages into a style profile
 */

import { Hono } from "hono";
import { formatStream } from "./streaming.js";
import { dictationStream } from "./dictation-stream.js";
import type {
  Env,
  CombinedResponse,
  ValidateCorrectionsResponse,
} from "./types.js";
import { UpstreamError } from "./http.js";
import { runFlowGraph } from "./graph.js";
import { validateCorrections } from "./validation.js";
import { buildStyleProfile } from "./profile.js";
import {
  parseCorrectionsRequest,
  parseStyleProfileRequest,
  parseTranscriptionRequest,
} from "./requests.js";

const app = new Hono<{ Bindings: Env }>();

/**
 * A provider failure is reported as a bad gateway rather than an internal
 * error, so a caller can tell "the upstream is down" from "this worker is
 * broken" and retry accordingly.
 */
function statusForGraphError(message: string): 500 | 502 {
  return message.startsWith("Workers AI error") ? 502 : 500;
}

app.get("/health", (c) => c.json({ status: "ok" }));

app.post("/transcribe-stream", async (c) => {
  let body: unknown;
  try { body = await c.req.json(); }
  catch { return c.json({ error: "invalid JSON" }, 400); }
  const parsed = parseTranscriptionRequest(body);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  return new Response(dictationStream(c.env, parsed.value, c.req.raw.signal), { headers: {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "X-Content-Type-Options": "nosniff",
  } });
});

// Native demo: partial speech arrives as text; completion tokens stream back.
app.post("/format-stream", async (c) => {
  let body: unknown;
  try { body = await c.req.json(); }
  catch { return c.json({ error: "invalid JSON" }, 400); }
  const parsed = parseTranscriptionRequest(body);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  if (!parsed.value.text?.trim() || parsed.value.audioB64) {
    return c.json({ error: "format-stream requires text, without audio" }, 400);
  }
  try {
    const stream = await formatStream(c.env, parsed.value, c.req.raw.signal);
    return new Response(stream, { headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      "X-Content-Type-Options": "nosniff",
    } });
  } catch {
    return c.json({ error: "The streaming provider is unavailable. Please retry." }, 502);
  }
});

/**
 * POST / - transcribe audio, then either format it or execute the command.
 *
 * Request body:
 * {
 *   "whisper_input": {
 *     "audio": { "audio_b64": "..." },
 *     "text": "optional typed text, skips transcription",
 *     "whisper_params": { "audio_language": "en", "prompt": "optional hint" }
 *   },
 *   "completion": {
 *     "mode": "casual",
 *     "app_context": "optional context",
 *     "shortcuts_triggered": [],
 *     "voice_instruction": "optional override",
 *     "personalization": "optional style profile and examples"
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
    attachment: result.attachment,
    attachment_protocol: result.attachmentProtocol,
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

/**
 * POST /style-profile
 *
 * Request body:  { "examples": [{ "category", "sent", "formatter_wrote?" }], "current_profile?": "..." }
 * Response:      { "profile": "markdown" }
 */
app.post("/style-profile", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid JSON" }, 400);
  }

  const parsed = parseStyleProfileRequest(body);
  if (!parsed.ok) {
    return c.json({ error: parsed.error }, 400);
  }

  try {
    const profile = await buildStyleProfile(
      c.env,
      parsed.value.examples,
      parsed.value.currentProfile
    );
    return c.json({ profile });
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    console.error(`profile failed: ${message}`);
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
