/** Bounded provider waits and actionable errors, without logging user input. */
export class AIUnavailable extends Error {
  constructor(readonly code: "quota_exhausted" | "rate_limited" | "timeout" | "unavailable", readonly status: number) {
    super(code === "quota_exhausted"
      ? "Cloudflare's daily AI allowance is exhausted. Enable Workers Paid or wait for the daily reset."
      : code === "rate_limited" ? "Cloudflare is temporarily rate limited. Please retry shortly."
      : code === "timeout" ? "Cloudflare did not respond in time. Your draft was not completed; please retry."
      : "Cloudflare AI is temporarily unavailable. Please retry.");
  }
}

export function aiFailure(error: unknown, status = 502): AIUnavailable {
  if (error instanceof AIUnavailable) return error;
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : JSON.stringify(error);
  if (/daily free allocation|daily.*(?:quota|allowance).*exhaust|used up.*neurons/i.test(message ?? "")) {
    return new AIUnavailable("quota_exhausted", 429);
  }
  return new AIUnavailable(status === 429 ? "rate_limited" : "unavailable", status);
}

/** AI bindings do not expose cancellation. Late sockets/streams must be closed. */
export async function boundedAI<T>(operation: () => Promise<T>, timeoutMs: number, disposeLate?: (value: T) => void): Promise<T> {
  let expired = false;
  let timer: ReturnType<typeof setTimeout>;
  const pending = Promise.resolve().then(operation).then(value => {
    if (expired) disposeLate?.(value);
    return value;
  });
  try {
    return await Promise.race([pending, new Promise<never>((_, reject) => {
      timer = setTimeout(() => { expired = true; reject(new AIUnavailable("timeout", 504)); }, timeoutMs);
    })]);
  } catch (error) { throw aiFailure(error); }
  finally { clearTimeout(timer!); }
}

export function speechFailureFrame(error: unknown, status = 502) {
  const failure = aiFailure(error, status);
  return { type: "Error", code: failure.code, message: failure.message };
}
