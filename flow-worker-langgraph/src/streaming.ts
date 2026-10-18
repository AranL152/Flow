import type { Env } from "./types.js";
import type { TranscriptionRequestInput } from "./requests.js";
import { buildFormattingPrompt, buildInstructionPrompt } from "./prompts.js";

/** Normalize real provider tokens to a small, version-independent SSE contract. */
export function normalizeStream(upstream: ReadableStream<Uint8Array>, signal?: AbortSignal): ReadableStream<Uint8Array> {
  const reader = upstream.getReader();
  const encoder = new TextEncoder();
  let cancelled = false;
  const abort = () => { cancelled = true; void reader.cancel(); };
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) abort();
  return new ReadableStream<Uint8Array>({
    async start(controller) {
      let text = "";
      let buffer = "";
      let data: string[] = [];
      let finished = false;
      const decoder = new TextDecoder();
      const emit = (event: string, payload: unknown) => {
        if (!cancelled) controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`));
      };
      const frame = () => {
        if (!data.length) return;
        const raw = data.join("\n"); data = [];
        if (raw === "[DONE]") { finished = true; return; }
        const value = JSON.parse(raw);
        if (value.error) throw new Error("The model stream failed. Please retry.");
        const choice = value.choices?.[0];
        if (choice?.finish_reason && choice.finish_reason !== "stop") throw new Error("The model stopped before finishing. Please retry with a shorter message.");
        const delta = value.response ?? choice?.delta?.content;
        if (delta !== undefined && delta !== null && typeof delta !== "string") throw new Error("Invalid model token");
        if (delta) {
          text += delta;
          if (text.length > 12000) throw new Error("Model output is too long");
          emit("delta", { text: delta });
        }
        if (choice?.finish_reason === "stop") finished = true;
      };
      const line = (value: string) => {
        value = value.replace(/\r$/, "");
        if (!value) frame();
        else if (value.startsWith("data:")) data.push(value.slice(5).replace(/^ /, ""));
      };
      try {
        while (!cancelled && !finished) {
          const chunk = await reader.read();
          if (chunk.done) break;
          buffer += decoder.decode(chunk.value, { stream: true });
          if (buffer.length > 50000) throw new Error("Invalid model stream");
          let end: number;
          while (!finished && (end = buffer.indexOf("\n")) >= 0) {
            line(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
          }
        }
        if (!finished && !cancelled) {
          buffer += decoder.decode();
          if (buffer) line(buffer);
          frame();
        }
        if (!cancelled) {
          if (!finished) throw new Error("The connection ended before the message finished. Retry to continue.");
          if (!text.trim()) throw new Error("The model returned no text");
          emit("done", { text: text.trim() });
        }
      } catch (error) {
        emit("error", { error: error instanceof Error ? error.message : "Streaming failed" });
      } finally {
        signal?.removeEventListener("abort", abort);
        await reader.cancel().catch(() => {});
        // An aborted request still closes the readable side. A consumer that
        // already cancelled it has closed it for us.
        try { controller.close(); } catch { /* already cancelled */ }
      }
    },
    cancel() { abort(); },
  });
}

export async function formatStream(env: Env, input: TranscriptionRequestInput, signal?: AbortSignal, instruction?: string) {
  if (input.autoRewritingEnabled === false) {
    const text = input.text ?? "";
    return new ReadableStream<Uint8Array>({ start(controller) {
      const encoder = new TextEncoder();
      controller.enqueue(encoder.encode(`event: delta\ndata: ${JSON.stringify({ text })}\n\nevent: done\ndata: ${JSON.stringify({ text: text.trim() })}\n\n`));
      controller.close();
    } });
  }
  const model = (env.CHAT_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast") as "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
  const result = await env.AI.run(model, {
    messages: [
      { role: "system", content: instruction ? buildInstructionPrompt(input.personalization, input.appContext) : buildFormattingPrompt(input.mode, input.appContext, input.shortcutsTriggered, input.personalization) },
      { role: "user", content: instruction ?? `<TRANSCRIPTION>\n${input.text}\n</TRANSCRIPTION>` },
    ],
    stream: true,
    max_tokens: 700,
    temperature: 0.2,
  });
  if (!result || typeof (result as ReadableStream).getReader !== "function") {
    throw new Error("The provider did not return a stream");
  }
  return normalizeStream(result as ReadableStream<Uint8Array>, signal);
}
