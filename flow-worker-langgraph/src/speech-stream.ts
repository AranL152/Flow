import type { Env } from "./types.js";

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
    const response = await env.AI.run("@cf/deepgram/nova-3", input as unknown as Ai_Cf_Deepgram_Nova_3_Input, { websocket: true });
    const upstream = response.webSocket;
    if (!upstream) {
      console.warn("Speech upgrade unavailable", response.status, (await response.text()).slice(0, 1000));
      return Response.json({ error: "Real-time speech unavailable" }, { status: 502 });
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
  } catch {
    return Response.json({ error: "Real-time speech unavailable; use recorded transcription" }, { status: 502 });
  }
}
