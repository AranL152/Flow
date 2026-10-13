/**
 * Shared JSON-over-HTTP transport for upstream calls.
 *
 * Every upstream call previously used a bare fetch with no timeout, so a hung
 * provider held the request open until the platform killed it. This adds a
 * deadline and a single retry for failures that are worth retrying, and keeps
 * provider error reporting in one shape.
 */

/** An upstream call failed. `status` is 0 for a transport error or timeout. */
export class UpstreamError extends Error {
  constructor(
    readonly service: string,
    readonly status: number,
    readonly detail: string
  ) {
    super(`${service} error ${status}: ${detail}`);
    this.name = "UpstreamError";
  }
}

export interface PostJsonOptions {
  /** Provider name, used in error messages */
  service: string;
  url: string;
  headers: Record<string, string>;
  body: unknown;
  timeoutMs: number;
  /** Additional attempts after the first (default 1) */
  retries?: number;
}

/** Overload and rate-limit responses are worth another attempt; 4xx is not. */
function isRetryableStatus(status: number): boolean {
  return status >= 500 || status === 429;
}

/** Kept short: this latency is in front of a user waiting to see their text. */
function backoffMs(attempt: number): number {
  return 150 * 2 ** (attempt - 1);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function truncate(text: string, max = 500): string {
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

export async function postJson<T>({
  service,
  url,
  headers,
  body,
  timeoutMs,
  retries = 1,
}: PostJsonOptions): Promise<T> {
  let lastError: UpstreamError | undefined;

  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) {
      await sleep(backoffMs(attempt));
    }

    let failure: { error: UpstreamError; retryable: boolean };

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });

      if (response.ok) {
        return (await response.json()) as T;
      }

      const detail = await response.text().catch(() => "");
      failure = {
        error: new UpstreamError(service, response.status, truncate(detail)),
        retryable: isRetryableStatus(response.status),
      };
    } catch (err) {
      // Transport error, abort from the deadline, or an unparseable body.
      const message = err instanceof Error ? err.message : String(err);
      failure = {
        error: new UpstreamError(service, 0, message),
        retryable: true,
      };
    }

    lastError = failure.error;
    if (!failure.retryable) {
      break;
    }
  }

  throw lastError ?? new UpstreamError(service, 0, "request failed");
}
