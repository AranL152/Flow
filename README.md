<div align="center">
  <img src="https://raw.githubusercontent.com/AranL152/Flow/main/Sources/FlowApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="96" alt="Flow logo" />
  <h1>Flow</h1>
  <p><b>Speak naturally. Write perfectly.</b></p>
  <p>Native Mac dictation with personalized writing and voice-driven attachments.</p>
  <a href="#demo"><b>Watch the demo →</b></a> · <a href="#setup">Build for Mac</a>
</div>

---

Built at **UofTHacks 13**, Flow is an open-source alternative to Wispr Flow.
This fork extends dictation with **Flow Commands**: use your voice to find a
relevant file, image, or screenshot and attach it directly to an iMessage draft.

Hold `Fn`, speak, and release. Flow separates what you want to say from what you
want it to do. You review the result and press Send yourself.

## Demo

**[Watch / download the Flow demo — 28 seconds, MP4](https://github.com/AranL152/Flow/releases/download/demo/FLOW-DEMO.mp4)**

A walkthrough in Messages: casual speech becomes a professional reply, a Flow
Command finds the Q2 report by its contents, and the named PDF appears in the
draft alongside a picker of other matches. Matched phrases are highlighted so
you can see why each document was found.

The recording uses scripted speech captions and formatted text for consistent
presentation. Document search and native Messages attachment insertion are real;
the clip is a product walkthrough, not an inference-latency benchmark.

[Demo release](https://github.com/AranL152/Flow/releases/tag/demo) ·
[Demo and verification notes](docs/demo.md)

## What it does

- **Flow Attach Commands.** Say “Here's the report. Flow, find the quarterly report PDF for Q2 2026.” The instruction stays out of your message. Flow searches locally, stages the best match, and offers alternatives you can preview or select to replace only Flow's attachment.
- **Clipboard and recent files.** Attach an image on your clipboard or a recently downloaded file without hunting through Finder.
- **Search inside screenshots, PDFs, and slides.** Apple Vision recognizes screenshot text; PDFKit and PowerPoint XML readers extract document text. Results explain the matched phrase and page or slide when available. This is text matching, not general image understanding.
- **Contact-aware personalization.** Recipient-specific style profiles and examples guide wording and tone. Corrections to completed, sent drafts become examples for future requests to that contact. Learning uses a local database and prompts; it does not retrain model weights.
- **Live captions and streamed writing.** See speech in the transcription box while recording. Formatted model output streams separately into supported text fields; raw speech captions stay out of the recipient's draft. The waveform responds to speech, and recognized attachment commands receive a purple ripple.
- **Local or cloud speech.** Choose offline, Metal-accelerated Whisper or Cloudflare-backed transcription and rewriting. Voice shortcuts can expand saved phrases such as “my email.”

Read more: [attachment commands](docs/attachment-commands.md),
[document search](docs/document-content-search.md),
[screenshot OCR](docs/screenshot-text-search.md), and
[personalization and streaming](docs/streamed-dictation.md).

## Engineering and stack

| Area | Technologies and engineering |
| --- | --- |
| Native macOS app | **Swift, SwiftUI, AppKit**; global hotkeys, microphone capture, live overlays, Quick Look previews, and macOS Accessibility integration. No Electron. |
| Core and learning | **Rust, C FFI, SQLite**; audio processing, recipient-scoped examples, personalized prompts, stream validation, and cancellation across the Rust–Swift boundary. |
| Cloud backend | **Cloudflare Workers and Workers AI**, **TypeScript, Hono, LangGraph**; HTTP routing, command detection, formatting, and streamed inference. The active backend is [`flow-worker-langgraph/`](flow-worker-langgraph/). |
| Speech models | **Deepgram Nova-3** through Workers AI over **WebSockets** for real-time cloud speech; **Whisper Large v3 Turbo** for batch recognition/fallback. Optional Apple Speech captions provide an on-device backup. |
| Language model | **Llama 3.3 70B Instruct** (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`) by default, configurable with `CHAT_MODEL`. Output travels over **SSE**, Rust callbacks, and Swift async streams. |
| Local retrieval | **Spotlight, Apple Vision OCR, PDFKit, ZIP/XML parsing**; filename and content search, bounded extraction, caches, and file-change validation. Document contents and image pixels stay on the Mac during attachment search. |
| Native insertion | Accessibility field/selection tracking and named rich-text file wrappers. Attachment replacement tracks the exact native object Flow added and preserves unrelated draft content. |
| Verification | **Rust tests, XCTest, Vitest**, worker typechecking, and native integration checks for streaming, OCR, document search, recipient learning, and unsent Messages drafts. |

Cloud Auto uses the configured Cloudflare worker's account rather than a client
OpenAI key. Cloud inference is provider-billed; local Whisper can run offline.
The older Rust worker in [`flow-worker/`](flow-worker/) is retained separately;
its optional Baseten path is not the current TypeScript backend's default.
See [real-time speech and measured timings](docs/cloud-speech.md) for the
WebSocket handoff, fallback behavior, and scoped latency results.

## App compatibility

**Messages:** native attachment insertion, alternative-file replacement, and
recipient-aware learning are integrated here. Flow never presses Send.

**Other Mac apps:** dictation targets the focused text field. Direct streaming
requires a compatible writable Accessibility field; otherwise Flow can use a
completed-text paste. Native paste was verified in a VS Code scratch document,
but VS Code's editor currently ignores direct Accessibility streaming writes.
Use buffered output there; streaming compatibility still needs work. Terminal
and Codex prompt insertion have not been verified.

## Setup

Requires **macOS 14+**, Xcode Command Line Tools, a Rust toolchain, and `cbindgen`.
Build this fork for its new features; the upstream DMG contains upstream code.

```sh
git clone https://github.com/AranL152/Flow
cd Flow
cargo install cbindgen --locked
python3 scripts/setup-native-signing.py --trust-local-certificate
python3 scripts/install-native.py
```

Signing setup is a one-time step on a new Mac. Updates reuse the same identity
so macOS can retain privacy grants. Grant Accessibility and microphone access
when needed; file search needs access to the folders being searched. Apple
Speech Recognition is optional for backup captions.

Reopen an existing installation without rebuilding:

```sh
python3 scripts/launch-native.py
```

See [native installation](docs/native-install.md) for signing and updates, and
[worker setup](flow-worker-langgraph/README.md) for backend development.

## Development checks

```sh
cargo test --manifest-path flow-core/Cargo.toml
swift test
npm --prefix flow-worker-langgraph ci
npm --prefix flow-worker-langgraph test
npm --prefix flow-worker-langgraph run typecheck
```

Native verification scripts are documented alongside each feature. They report
which paths were actually exercised; simulated text, generated speech, and
physical microphone checks are different tests.

## Credits

This fork builds on [Jason Cameron's Flow](https://github.com/JasonLovesDoggo/Flow).
See [upstream integration notes](docs/upstream-sync.md) for the shared foundation
and fork additions.

MIT licensed.
