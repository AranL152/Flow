import { describe, expect, it, vi } from "vitest";
import { dictationStream } from "./dictation-stream.js";
import type { Env } from "./types.js";
import app from "./index.js";
import { runFlowGraph } from "./graph.js";

const input = { audioB64: "AAAA", audioLanguage: "en", mode: "casual", shortcutsTriggered: [] };
const encode = new TextEncoder();
const finished = (text: string) => new ReadableStream<Uint8Array>({ start(c) {
  c.enqueue(encode.encode(`data: ${JSON.stringify({ response: text })}\n\ndata: [DONE]\n\n`)); c.close();
} });

describe("native streamed dictation", () => {
  it("streams just the message and preserves search terms outside the model prompt", async () => {
    const run = vi.fn().mockResolvedValue(finished("here's the file"));
    const output = await new Response(dictationStream({ AI: { run } } as unknown as Env,
      { ...input, audioB64: "", text: "Here's the file. Flow find my robotics presentation", attachmentCommandsEnabled: true, attachmentSearchEnabled: true })).text();
    expect(run.mock.calls[0][1].messages[1].content).toBe("<TRANSCRIPTION>\nHere's the file.\n</TRANSCRIPTION>");
    expect(output).toContain('"source":"file_search","kind":"presentation","query":"robotics"');
    expect(output).toContain('event: delta');
  });
  it("keeps attachment instructions out of every generated chunk", async () => {
    const run = vi.fn().mockResolvedValue(finished("here's the deck"));
    const output = await new Response(dictationStream({ AI: { run } } as unknown as Env,
      { ...input, audioB64: "", text: "Here's the deck. Flow, attach the PDF I just downloaded.", attachmentCommandsEnabled: true })).text();
    expect(run.mock.calls[0][1].messages[1].content).toBe("<TRANSCRIPTION>\nHere's the deck.\n</TRANSCRIPTION>");
    expect(output).toContain('"source":"recent_download","kind":"pdf"');
    expect(output).toContain('"attachment_protocol":1');
    expect(output).toContain('event: delta\ndata: {"text":"here\'s the deck"}');
  });

  it("handles attachment-only and unsupported requests without inventing text", async () => {
    for (const text of ["Flow attach my clipboard", "Flow attach yesterday's screenshot"]) {
      const run = vi.fn();
      const output = await new Response(dictationStream({ AI: { run } } as unknown as Env,
        { ...input, audioB64: "", text, attachmentCommandsEnabled: true })).text();
      expect(output).toContain('event: done\ndata: {"text":""}');
      expect(output).not.toContain("event: delta");
      expect(run).not.toHaveBeenCalled();
    }
  });

  it("uses the same attachment boundary in buffered and raw modes", async () => {
    const run = vi.fn();
    const result = await runFlowGraph({ ...input, audioB64: "", text: "Here's the file. Flow attach the file on my clipboard",
      attachmentCommandsEnabled: true, autoRewritingEnabled: false, env: { AI: { run } } as unknown as Env });
    expect(result.formattedText).toBe("Here's the file.");
    expect(result.attachment?.request?.source).toBe("clipboard");
    expect(result.transcription).toContain("Flow attach");
    expect(run).not.toHaveBeenCalled();
  });
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
  it("passes the user's current-contact edits into streamed agentic generation", async () => {
    const run = vi.fn().mockResolvedValue(finished("yo can u check the deck on Friday?"));
    const personalization = 'Alex correction: formatter wrote "slides" → user sent "deck"';
    const response = await new Response(dictationStream({ AI: { run } } as unknown as Env,
      { ...input, audioB64: "", text: "Hey Flow ask for a slides review on Friday", appContext: "Messages, current contact", personalization })).text();
    const request = run.mock.calls[0][1];
    expect(request.messages[0].content).toContain(personalization);
    expect(request.messages[0].content).toContain("Current writing context: Messages, current contact");
    expect(request.messages[0].content).toContain("Current explicit instructions override history");
    expect(request.messages[1].content).toBe("ask for a slides review on Friday");
    expect(response).toContain("event: done");
  });

  it("passes the same edits into buffered agentic generation", async () => {
    const run = vi.fn().mockResolvedValue({ response: "yo can u check the deck on Friday?" });
    const personalization = 'This user writes "deck" to Alex';
    const result = await runFlowGraph({ ...input, audioB64: "", text: "Hey Flow ask for a slides review on Friday", personalization,
      env: { AI: { run } } as unknown as Env });
    expect(result.formattedText).toBe("yo can u check the deck on Friday?");
    expect(run.mock.calls[0][1].messages[0].content).toContain(personalization);
  });

});
