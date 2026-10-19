import { aiFailure } from "./ai-availability.js";

/** One delayed duplicate protects first-token latency. Only one complete stream
 * wins; never splice models or retry after displaying a token. */
export async function responsiveRewrite(
  create: (signal: AbortSignal) => Promise<ReadableStream<Uint8Array>>,
  signal?: AbortSignal,
  hedgeMs = 800,
): Promise<ReadableStream<Uint8Array>> {
  const controllers = [new AbortController(), new AbortController()];
  let fatal: Error | undefined;
  let rejectAbort: (error: Error) => void;
  const stop = () => controllers.forEach(controller => controller.abort());
  const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; });
  const abort = () => { stop(); rejectAbort(new Error("Dictation cancelled")); };
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) abort();

  const attempt = async (controller: AbortController, delayed: boolean) => {
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
      if (delayed) await new Promise<void>((resolve, reject) => {
        if (controller.signal.aborted) { reject(new Error("Cancelled")); return; }
        const cancel = () => { clearTimeout(timer); reject(new Error("Cancelled")); };
        const timer = setTimeout(() => { controller.signal.removeEventListener("abort", cancel); resolve(); }, hedgeMs);
        controller.signal.addEventListener("abort", cancel, { once: true });
      });
      if (controller.signal.aborted || fatal) throw fatal ?? new Error("Cancelled");
      const stream = await create(controller.signal);
      reader = stream.getReader();
      const first = await reader.read();
      if (controller.signal.aborted) throw new Error("Cancelled");
      if (first.done) throw new Error("The formatter returned no tokens");
      const frame = new TextDecoder().decode(first.value);
      if (!frame.startsWith("event: delta\n")) {
        const data = frame.split("\ndata: ")[1]?.trim();
        let message = "The formatter did not start a complete draft";
        try { message = JSON.parse(data ?? "{}").error ?? message; } catch {}
        throw aiFailure(message);
      }
      return { reader, first: first.value, controller };
    } catch (error) {
      void reader?.cancel().catch(() => {});
      const failure = aiFailure(error);
      if (failure.code === "quota_exhausted") { fatal = failure; stop(); }
      throw failure;
    }
  };

  try {
    const winner = await Promise.race([Promise.any([
      attempt(controllers[0], false), attempt(controllers[1], true),
    ]), aborted]);
    controllers.filter(controller => controller !== winner.controller).forEach(controller => controller.abort());
    const cleanup = () => signal?.removeEventListener("abort", abort);
    return new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(winner.first); },
      async pull(controller) {
        try {
          const next = await winner.reader.read();
          if (next.done) { cleanup(); controller.close(); }
          else controller.enqueue(next.value);
        } catch (error) { cleanup(); controller.error(error); }
      },
      async cancel() { cleanup(); stop(); await winner.reader.cancel().catch(() => {}); },
    });
  } catch (error) {
    stop(); signal?.removeEventListener("abort", abort);
    throw fatal ?? aiFailure(error);
  }
}
