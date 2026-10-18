# Inference latency — October 18, 2026

This records the investigation before implementation. The real-time Cloudflare
path is now implemented; see [cloud-speech.md](cloud-speech.md) for the deployed
route, costs, fallback behavior and scoped live verification. The UI-only ripple
preview itself still makes no ASR/LLM calls.

## What Jason's sync contributed

The 36-commit merge is recorded in [upstream-sync.md](upstream-sync.md).
Relevant upstream changes include waveform rendering (`08f8c3b`), helper restart
and error handling (`e8a6bb1`), hotkey activation modes (`3cd8918`), correction
alignment/punctuation and UPSERT fixes (`cf2f61c`, `5574685`), and custom
OpenAI-compatible API base URLs (`c4f4f0b`). These improve reliability and give
us an integration route to another inference host; they do not establish a
measured latency improvement for this fork's streaming demo.

Jason's Rust worker supports Cloudflare Whisper by default or a Baseten predict
endpoint when TRANSCRIPTION_PROVIDER=base10, followed by OpenRouter formatting.
Our Auto streaming provider instead calls flow-worker-langgraph at the retained
base10-proxy URL. Its checked-in configuration uses Cloudflare Workers AI:
whisper-large-v3-turbo, then llama-3.3-70b-instruct-fp8-fast unless CHAT_MODEL is
overridden. The service name alone does not identify the inference provider.
Deployed environment overrides have not been inspected for this investigation.

## Changes to measure first

1. Measure Stop → final ASR → first model delta → first native write separately
   from the intentionally paced display duration. Compare median and p95 using
   the same utterances, recipient context and correctness checks.
2. Transcribe while the user speaks. Today the final cloud request still runs
   batch Whisper after Stop, before starting the rewrite. Cloudflare supports
   [Nova-3 and Flux over WebSockets](https://developers.cloudflare.com/ai-gateway/usage/websockets-api/realtime-api/).
   Evaluate that path, or reuse a validated final on-device transcript with a
   cloud fallback. Keep partial speech out of the recipient's draft.
3. Benchmark a smaller formatting model with only relevant recipient examples.
   Check personalization, command separation and attachment metadata before
   changing the default. Model size alone cannot guarantee better latency.
4. Keep the smooth reveal independent of inference. Our 40 ms display pacing
   plus punctuation pauses is deliberate; faster inference should reduce the
   wait before the first character without forcing abrupt native insertions.

## Using the RTX 4080

Keep the Swift app on the Mac and run an inference service on the Windows/Linux
PC containing the GPU. The Mac streams requests over the network. A practical
ASR candidate is [faster-whisper](https://github.com/SYSTRAN/faster-whisper),
which supports CUDA and quantized GPU inference; its published benchmarks even
use an 8 GB RTX 3070 Ti. Those long-audio throughput results are not a measurement
of our short-utterance latency on the 4080.

Pair it with a small quantized rewriting model, budget VRAM for both resident
models and context, and benchmark against cloud inference. The current 70B FP8
model cannot fit on a single 4080. The existing custom API base URL setting is
useful groundwork, but Auto's streamed events, personalization and attachment
protocol still need a compatible adapter. There is no GPU service configured
or connected by this UI task.

Baseten also offers [WebSocket model serving](https://www.baseten.co/resources/changelog/websocket-support-for-real-time-model-streaming/).
That is another candidate to benchmark; the upstream batch predict call does
not automatically provide real-time ASR. No sub-10 ms end-to-end claim has been
verified for either architecture.
