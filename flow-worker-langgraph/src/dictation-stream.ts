import type { Env, FlowState } from "./types.js";
import type { TranscriptionRequestInput } from "./requests.js";
import { transcribeNode, detectWakePhraseNode, executeNode } from "./nodes.js";
import { formatStream } from "./streaming.js";

/** Native dictation: Whisper first, then genuine LLM deltas in one request. */
export function dictationStream(env: Env, input: TranscriptionRequestInput, signal?: AbortSignal): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  let cancelled = signal?.aborted ?? false;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const abort = () => { cancelled = true; void reader?.cancel(); };
  signal?.addEventListener("abort", abort, { once: true });
  return new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (event: string, payload: unknown) => {
        if (!cancelled) controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`));
      };
      try {
        if (cancelled) return;
        let state: FlowState = { ...input };
        state = { ...state, ...await transcribeNode(state, { configurable: { env } }) };
        if (state.error) throw new Error(state.error);
        if (cancelled) return;
        emit("transcription", { text: state.transcription });
        state = { ...state, ...detectWakePhraseNode(state) };
        if (state.resolvedCommand) {
          const result = executeNode(state);
          if (result.action) throw new Error("This action is unavailable in streamed dictation.");
          if (!result.formattedText?.trim()) throw new Error(result.error ?? "The command returned no text");
          emit("delta", { text: result.formattedText });
          emit("done", { text: result.formattedText.trim() });
          return;
        }
        const stream = await formatStream(env, { ...input, text: state.transcription }, signal, state.detectedCommand);
        reader = stream.getReader();
        if (cancelled) { await reader.cancel(); return; }
        while (!cancelled) {
          const chunk = await reader.read();
          if (chunk.done) break;
          if (!cancelled) controller.enqueue(chunk.value);
        }
      } catch (error) {
        emit("error", { error: error instanceof Error ? error.message : "Dictation stream failed" });
      } finally {
        signal?.removeEventListener("abort", abort);
        await reader?.cancel().catch(() => {});
        try { controller.close(); } catch { /* consumer already cancelled */ }
      }
    },
    cancel() { abort(); },
  });
}
