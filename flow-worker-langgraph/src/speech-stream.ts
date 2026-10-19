import type { Env } from "./types.js";
import { aiFailure, boundedAI, speechFailureFrame } from "./ai-availability.js";

function unavailable(error: unknown): Response {
  // A failed HTTP upgrade hides the response body from URLSessionWebSocketTask.
  // Complete the upgrade and deliver the actual failure through the protocol.
  const failure = speechFailureFrame(error);
  console.warn("Speech unavailable", failure.code);
  const pair = new WebSocketPair();
  pair[1].accept();
  pair[1].send(JSON.stringify(failure));
  pair[1].close(1013, failure.code);
  return new Response(null, { status: 101, webSocket: pair[0] });
}

/** No client API key or second speech service: audio stays on Workers AI. */
export async function speechStream(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return Response.json({ error: "WebSocket upgrade required" }, { status: 426 });
  }
  const rate = Number(new URL(request.url).searchParams.get("sample_rate"));
  if (!Number.isInteger(rate) || rate < 8000 || rate > 48000) {
    return Response.json({ error: "Expected mono PCM16 at 8–48 kHz" }, { status: 400 });
  }
  try {
    // WebSocket model parameters are strings, unlike the batch model schema.
    const input = {
      encoding: "linear16", sample_rate: String(rate), channels: "1",
      language: "en", interim_results: "true", punctuate: "true",
      smart_format: "false", endpointing: "300", keyterm: "Flow",
    };
    const connect = () => boundedAI(() => env.AI.run("@cf/deepgram/nova-3", input as unknown as Ai_Cf_Deepgram_Nova_3_Input, { websocket: true }), 3000,
      response => response.webSocket?.close(1000, "Connection deadline exceeded"));
    let response = await connect();
    if (!response.webSocket) {
      const failure = aiFailure(await response.text(), response.status);
      // Retry only a transient startup failure, before any audio is accepted.
      // Quota failures require billing/reset, not another billable attempt.
      if (failure.code !== "quota_exhausted" && response.status >= 500) {
        await new Promise(resolve => setTimeout(resolve, 150));
        response = await connect();
      } else { return unavailable(failure); }
    }
    const upstream = response.webSocket;
    if (!upstream) {
      return unavailable(aiFailure(await response.text(), response.status));
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept(); upstream.accept();
    let bytes = 0, closing = false, closed = false;
    let idle: ReturnType<typeof setTimeout>;
    const close = (code = 1000, reason = "Finished") => {
      if (closed) return;
      closed = true; clearTimeout(idle); clearTimeout(deadline);
      server.close(code, reason); upstream.close(code, reason);
    };
    const deadline = setTimeout(() => close(1008, "Five minute limit"), 310000);
    const touch = () => {
      clearTimeout(idle);
      idle = setTimeout(() => close(1008, "Audio stopped"), 10000);
    };
    touch();
    server.addEventListener("message", event => {
      if (closed) return;
      try {
        if (event.data instanceof ArrayBuffer && !closing) {
          bytes += event.data.byteLength;
          if (event.data.byteLength % 2 || bytes > rate * 2 * 300) {
            close(1008, "Audio limit exceeded"); return;
          }
          upstream.send(event.data); touch();
        } else if (typeof event.data === "string" && !closing && event.data.length <= 64 &&
                   JSON.parse(event.data).type === "CloseStream") {
          closing = true; upstream.send('{"type":"CloseStream"}'); touch();
        } else { close(1008, "Invalid speech frame"); }
      } catch { close(1008, "Invalid speech frame"); }
    });
    upstream.addEventListener("message", event => {
      if (!closed) server.send(event.data);
    });
    upstream.addEventListener("close", () => close());
    server.addEventListener("close", () => close());
    upstream.addEventListener("error", () => close(1011, "Speech service interrupted"));
    server.addEventListener("error", () => close(1011, "Speech connection interrupted"));
    return new Response(null, { status: 101, webSocket: client });
  } catch (error) {
    return unavailable(error);
  }
}
