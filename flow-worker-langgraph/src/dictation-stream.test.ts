import { describe, expect, it, vi } from "vitest";
import { dictationStream } from "./dictation-stream.js";
import type { Env } from "./types.js";
import app from "./index.js";

const input = { audioB64: "AAAA", audioLanguage: "en", mode: "casual", shortcutsTriggered: [] };
const encode = new TextEncoder();
const finished = (text: string) => new ReadableStream<Uint8Array>({ start(c) {
  c.enqueue(encode.encode(`data: ${JSON.stringify({ response: text })}\n\ndata: [DONE]\n\n`)); c.close();
} });

describe("native streamed dictation", () => {
  it("emits the transcription and first real tokens before generation finishes", async () => {
    let model!: ReadableStreamDefaultController<Uint8Array>;
    const run = vi.fn().mockResolvedValueOnce({ text: "can you review the slides" })
      .mockResolvedValueOnce(new ReadableStream<Uint8Array>({ start(c) { model = c; } }));
    const stream = dictationStream({ AI: { run } } as unknown as Env, input).getReader();
    expect(new TextDecoder().decode((await stream.read()).value)).toContain("event: transcription");
    model.enqueue(encode.encode('data: {"response":"got a sec"}\n\n'));
    expect(new TextDecoder().decode((await stream.read()).value)).toContain('"text":"got a sec"');
    model.enqueue(encode.encode('data: {"response":" to review the slides?"}\n\ndata: [DONE]\n\n')); model.close();
    let rest = "";
    for (;;) { const next = await stream.read(); if (next.done) break; rest += new TextDecoder().decode(next.value); }
    expect(rest).toContain('event: done\ndata: {"text":"got a sec to review the slides?"}');
    expect(run.mock.calls[1][1].stream).toBe(true);
  });

  it("preserves raw mode and commands without an unnecessary model", async () => {
    for (const [text, enabled, expected] of [["Hey Flow uppercase hello", true, "HELLO"], ["Hey Flow uppercase hello", false, "Hey Flow uppercase hello"]] as const) {
      const run = vi.fn();
      const response = await new Response(dictationStream({ AI: { run } } as unknown as Env,
        { ...input, audioB64: "", text, autoRewritingEnabled: enabled })).text();
      expect(response).toContain(JSON.stringify({ text: expected }));
      expect(response).toContain("event: done");
      expect(run).not.toHaveBeenCalled();
    }
  });

  it("streams explicit instructions using the instruction prompt", async () => {
    const run = vi.fn().mockResolvedValue(finished("Thank you for asking."));
    const response = await new Response(dictationStream({ AI: { run } } as unknown as Env,
      { ...input, audioB64: "", text: "Hey Flow decline the invitation politely" })).text();
    expect(run.mock.calls[0][1].messages[1].content).toBe("decline the invitation politely");
    expect(response).toContain("event: done");
  });

  it("errors do not turn a partial draft into a completed message", async () => {
    const run = vi.fn().mockResolvedValue(new ReadableStream<Uint8Array>({ start(c) {
      c.enqueue(encode.encode('data: {"response":"partial"}\n\n')); c.close();
    } }));
    const response = await new Response(dictationStream({ AI: { run } } as unknown as Env,
      { ...input, audioB64: "", text: "check this" })).text();
    expect(response).toContain("event: error");
    expect(response).not.toContain("event: done");
  });

  it("validates input before inference", async () => {
    const run = vi.fn();
    const response = await app.request("/transcribe-stream", { method: "POST", body: "{}" }, { AI: { run } } as unknown as Env);
    expect(response.status).toBe(400);
    expect(run).not.toHaveBeenCalled();
  });
});
