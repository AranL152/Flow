import { describe, expect, it, vi } from "vitest";
import { runFlowGraph } from "./graph.js";
import { parseTranscriptionRequest } from "./requests.js";
import { formatStream } from "./streaming.js";
import type { Env } from "./types.js";

describe("upstream raw dictation setting with the fork worker", () => {
  it("preserves the switch and rejects values that only look boolean", () => {
    const body = { whisper_input: { text: "hello" }, completion: { mode: "casual", auto_rewriting_enabled: false } };
    const parsed = parseTranscriptionRequest(body);
    expect(parsed.ok && parsed.value.autoRewritingEnabled).toBe(false);
    expect(parseTranscriptionRequest({ ...body, completion: { ...body.completion, auto_rewriting_enabled: "false" } }).ok).toBe(false);
  });

  it("returns raw wording without executing a wake command or calling a model", async () => {
    const run = vi.fn();
    const text = "Hey Flow, uppercase keep my wording";
    const state = await runFlowGraph({ audioB64: "", audioLanguage: "en", mode: "formal", text, autoRewritingEnabled: false, env: { AI: { run } } as unknown as Env });
    expect(state.error).toBeUndefined();
    expect(state.formattedText).toBe(text);
    expect(state.command).toBeUndefined();
    expect(run).not.toHaveBeenCalled();
  });

  it("also bypasses formatting on the streaming endpoint", async () => {
    const run = vi.fn();
    const text = "my exact wording";
    const stream = await formatStream({ AI: { run } } as unknown as Env, { audioB64: "", audioLanguage: "en", mode: "formal", shortcutsTriggered: [], text, autoRewritingEnabled: false });
    expect(await new Response(stream).text()).toContain(`event: done\ndata: ${JSON.stringify({ text })}`);
    expect(run).not.toHaveBeenCalled();
  });
});
