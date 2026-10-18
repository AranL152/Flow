import { describe, expect, it, vi } from "vitest";
import { speechStream } from "./speech-stream.js";
import type { Env } from "./types.js";

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
    const run = vi.fn().mockResolvedValue(new Response("unavailable", { status: 503 }));
    const response = await speechStream(new Request("https://flow/speech-stream?sample_rate=16000", { headers: { Upgrade: "websocket" } }), { AI: { run } } as unknown as Env);
    expect(response.status).toBe(502);
    expect(run).toHaveBeenCalledWith("@cf/deepgram/nova-3", expect.objectContaining({ encoding: "linear16", sample_rate: "16000", interim_results: "true" }), { websocket: true });
  });
});
