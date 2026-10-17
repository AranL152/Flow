import { describe, expect, it, vi } from "vitest";
import { normalizeStream } from "./streaming.js";
import app from "./index.js";

const bytes = new TextEncoder();
function source(text: string, split = 1) {
  const raw = bytes.encode(text);
  return new ReadableStream<Uint8Array>({ start(c) {
    for (let i=0; i<raw.length; i+=split) c.enqueue(raw.slice(i, i+split));
    c.close();
  } });
}
const read = (s: ReadableStream<Uint8Array>) => new Response(s).text();
describe("real streaming", () => {
  it("preserves split Unicode and CRLF frames", async () => {
    const text = await read(normalizeStream(source('data: {"response":"hi ❤️"}\r\n\r\ndata: {"response":" mum"}\n\ndata: [DONE]\n\n')));
    expect(text).toContain('event: delta\ndata: {"text":"hi ❤️"}');
    expect(text).toContain('event: done\ndata: {"text":"hi ❤️ mum"}');
  });
  it("supports OpenAI deltas and stop markers", async () => {
    const text = await read(normalizeStream(source('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')));
    expect(text).toContain('event: done\ndata: {"text":"Hello"}');
  });
  it.each([
    'data: {"response":"partial"}\n\n',
    'data: {"error":"failure"}\n\n',
    'data: malformed\n\n',
    'data: [DONE]\n\n',
    'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}\n\n',
  ])("does not mark failed/truncated streams done", async input => {
    const text = await read(normalizeStream(source(input)));
    expect(text).toContain("event: error");
    expect(text).not.toContain("event: done");
  });
  it("delivers a token before the upstream has finished", async () => {
    let upstream!: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({ start(c) { upstream = c; } });
    const reader = normalizeStream(stream).getReader();
    upstream.enqueue(bytes.encode('data: {"response":"live"}\n\n'));
    expect(new TextDecoder().decode((await reader.read()).value)).toContain('"live"');
    await reader.cancel();
  });
  it("cancels upstream when the client disconnects", async () => {
    const cancel = vi.fn();
    const reader = normalizeStream(new ReadableStream({ cancel })).getReader();
    await reader.cancel();
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("an aborted request closes without a done event", async () => {
    const abort = new AbortController();
    const cancel = vi.fn();
    const stream = normalizeStream(new ReadableStream({ cancel }), abort.signal);
    abort.abort();
    expect(await read(stream)).toBe("");
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("rejects invalid requests before calling a model", async () => {
    const run = vi.fn();
    const response = await app.request('/format-stream', { method:'POST', body:JSON.stringify({}) }, { AI: { run } } as any);
    expect(response.status).toBe(400); expect(run).not.toHaveBeenCalled();
  });
  it("does not pretend a buffered model response is streaming", async () => {
    const response = await app.request('/format-stream', { method:'POST', body:JSON.stringify({whisper_input:{text:'hello',whisper_params:{audio_language:'en'}},completion:{mode:'casual'}}) }, { AI: { run:vi.fn().mockResolvedValue({response:'buffered'}) } } as any);
    expect(response.status).toBe(502);
  });
});
