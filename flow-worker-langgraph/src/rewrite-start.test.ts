import { afterEach, describe, expect, it, vi } from "vitest";
import { responsiveRewrite } from "./rewrite-start.js";

const bytes = new TextEncoder();
const delta = (text: string) => bytes.encode(`event: delta\ndata: ${JSON.stringify({ text })}\n\n`);
const read = (stream: ReadableStream<Uint8Array>) => new Response(stream).text();
function complete(text: string) {
  return new ReadableStream<Uint8Array>({ start(c) {
    c.enqueue(delta(text)); c.enqueue(bytes.encode(`event: done\ndata: ${JSON.stringify({ text })}\n\n`)); c.close();
  } });
}
afterEach(() => vi.useRealTimers());

describe("responsive rewrite startup", () => {
  it("uses one call when the primary starts promptly", async () => {
    const create = vi.fn().mockResolvedValue(complete("hello"));
    expect(await read(await responsiveRewrite(create))).toContain('"hello"');
    expect(create).toHaveBeenCalledOnce();
  });
  it("uses one delayed backup for a stalled first token and cancels the loser", async () => {
    vi.useFakeTimers();
    const cancel = vi.fn();
    const create = vi.fn(async (signal: AbortSignal) => {
      if (create.mock.calls.length > 1) return complete("backup");
      return new ReadableStream<Uint8Array>({ start(c) { signal.addEventListener("abort", () => { cancel(); c.close(); }); } });
    });
    const pending = responsiveRewrite(create);
    await vi.advanceTimersByTimeAsync(800);
    const output = await read(await pending);
    expect(output).toContain('"backup"');
    expect(create).toHaveBeenCalledTimes(2);
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("never duplicates requests after the first displayed token", async () => {
    vi.useFakeTimers();
    const create = vi.fn().mockResolvedValue(complete("primary"));
    const output = await read(await responsiveRewrite(create));
    await vi.advanceTimersByTimeAsync(2000);
    expect(output).toContain('"primary"');
    expect(create).toHaveBeenCalledOnce();
  });
  it("does not hedge an exhausted quota", async () => {
    const create = vi.fn().mockResolvedValue(new ReadableStream({ start(c) {
      c.enqueue(bytes.encode('event: error\ndata: {"error":"Cloudflare daily AI allowance is exhausted"}\n\n')); c.close();
    } }));
    await expect(responsiveRewrite(create)).rejects.toMatchObject({ code: "quota_exhausted" });
    expect(create).toHaveBeenCalledOnce();
  });
  it("aborts without starting the delayed duplicate when the client leaves", async () => {
    vi.useFakeTimers();
    const controller = new AbortController();
    const create = vi.fn().mockImplementation(() => new Promise(() => {}));
    const pending = responsiveRewrite(create, controller.signal);
    const check = expect(pending).rejects.toThrow();
    controller.abort(); await check;
    await vi.advanceTimersByTimeAsync(2000);
    expect(create).toHaveBeenCalledOnce();
  });
});
