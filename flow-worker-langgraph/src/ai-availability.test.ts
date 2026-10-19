import { afterEach, describe, expect, it, vi } from "vitest";
import { AIUnavailable, aiFailure, boundedAI, speechFailureFrame } from "./ai-availability.js";

afterEach(() => vi.useRealTimers());

describe("AI availability", () => {
  it("distinguishes exhausted daily quota from a transient rate limit without echoing provider details", () => {
    const error = aiFailure('AiError 4006: you have used up your daily free allocation of 10,000 neurons; private request ID', 429);
    expect(error.code).toBe("quota_exhausted");
    expect(error.message).toContain("Workers Paid");
    expect(error.message).not.toContain("private");
    expect(aiFailure("busy", 429).code).toBe("rate_limited");
    expect(speechFailureFrame(error)).toMatchObject({ type: "Error", code: "quota_exhausted" });
  });

  it("ends a hung binding call and disposes of a socket that arrives after the deadline", async () => {
    vi.useFakeTimers();
    let resolve!: (value: { close: () => void }) => void;
    const close = vi.fn();
    const pending = boundedAI(() => new Promise<{ close: () => void }>(done => { resolve = done; }), 100,
      socket => socket.close());
    const check = expect(pending).rejects.toMatchObject({ code: "timeout", status: 504 });
    await vi.advanceTimersByTimeAsync(100); await check;
    resolve({ close }); await vi.advanceTimersByTimeAsync(1);
    expect(close).toHaveBeenCalledOnce();
  });

  it("does not wait for a timeout or retry an explicit quota rejection", async () => {
    const operation = vi.fn().mockRejectedValue(new AIUnavailable("quota_exhausted", 429));
    await expect(boundedAI(operation, 3000)).rejects.toMatchObject({ code: "quota_exhausted" });
    expect(operation).toHaveBeenCalledOnce();
  });
});
