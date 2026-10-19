import { afterEach, describe, expect, it, vi } from "vitest";
import { speechStream } from "./speech-stream.js";
import type { Env } from "./types.js";

afterEach(() => vi.unstubAllGlobals());

function captureFailureSocket() {
  const send = vi.fn(), close = vi.fn();
  const NativeResponse = Response;
  vi.stubGlobal("WebSocketPair", class {
    0 = {};
    1 = { accept: vi.fn(), send, close };
  });
  vi.stubGlobal("Response", class extends NativeResponse {
    constructor(body?: BodyInit | null, options?: ResponseInit) {
      super(body, options?.status === 101 ? { status: 200 } : options);
      if (options?.status === 101) Object.defineProperty(this, "status", { value: 101 });
    }
  });
  return { send, close };
}

describe("real-time speech upgrade", () => {
  it("rejects non-WebSocket and invalid rates before billable inference", async () => {
    const run = vi.fn();
    const env = { AI: { run } } as unknown as Env;
    expect((await speechStream(new Request("https://flow/speech-stream?sample_rate=16000"), env)).status).toBe(426);
    for (const rate of ["", "NaN", "44100.5", "7999", "96000"]) {
      const response = await speechStream(new Request(`https://flow/speech-stream?sample_rate=${rate}`, { headers: { Upgrade: "websocket" } }), env);
      expect(response.status).toBe(400);
    }
    expect(run).not.toHaveBeenCalled();
  });
  it("requests actual incremental recognition and reports an unavailable upgrade", async () => {
    const { send } = captureFailureSocket();
    const run = vi.fn().mockResolvedValue(new Response("unavailable", { status: 503 }));
    const response = await speechStream(new Request("https://flow/speech-stream?sample_rate=16000", { headers: { Upgrade: "websocket" } }), { AI: { run } } as unknown as Env);
    expect(response.status).toBe(101);
    expect(JSON.parse(send.mock.calls[0][0])).toMatchObject({ type: "Error", code: "unavailable" });
    expect(run).toHaveBeenCalledTimes(2);
    expect(run).toHaveBeenCalledWith("@cf/deepgram/nova-3", expect.objectContaining({ encoding: "linear16", sample_rate: "16000", interim_results: "true" }), { websocket: true });
  });
  it("delivers quota errors through the socket without retrying a paid model", async () => {
    const { send, close } = captureFailureSocket();
    const run = vi.fn().mockResolvedValue(new Response('you have used up your daily free allocation of 10,000 neurons', { status: 429 }));
    const response = await speechStream(new Request("https://flow/speech-stream?sample_rate=48000", { headers: { Upgrade: "websocket" } }), { AI: { run } } as unknown as Env);
    expect(response.status).toBe(101);
    expect(run).toHaveBeenCalledOnce();
    expect(JSON.parse(send.mock.calls[0][0])).toMatchObject({ code: "quota_exhausted" });
    expect(close).toHaveBeenCalledWith(1013, "quota_exhausted");
  });
});
