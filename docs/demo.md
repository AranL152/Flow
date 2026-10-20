# Flow demos

## Messages walkthrough

[Watch / download the 28-second demo](https://github.com/AranL152/Flow/releases/download/demo/FLOW-DEMO.mp4)
([release page](https://github.com/AranL152/Flow/releases/tag/demo)).

The current recording shows the native transcription overlay, a Flow Attach
Command, local PDF content search, a named attachment in an unsent Messages
draft, and alternative matches with bold matching phrases. Speech captions and
the formatted reply are scripted for presentation; local search and native
attachment insertion use the app components. It is not a live inference or
latency benchmark. The private recording fixtures are not committed.

The cloud-backed implementation and its separate verification are documented in
[real-time speech](cloud-speech.md), [streamed dictation](streamed-dictation.md),
and [attachment commands](attachment-commands.md).

## Isolated conversation prototype

The three-card screen is an **internal test harness**, not a replacement for
Flow's product UI. It is available only by launching with `--demo`. The website
video should retain Flow's actual recording indicator and native UI, using
Hyperframes for explanatory connections, zooms, captions and edit receipts.

## Run the real pipeline locally

In a terminal, keep the worker running:

```sh
cd flow-worker-langgraph
npm install
npx wrangler dev --port 8787 --ip 127.0.0.1
```

Use local mode. Wrangler's AI binding still calls real Cloudflare models using
your authenticated account and incurs inference usage. Remote preview sessions
failed on this account during verification; local mode with remote AI worked.
The production worker has **not** been deployed by this change.

From the repository root, build and open the separate demo bundle:

```sh
cargo install cbindgen --locked # one-time prerequisite after the upstream sync
python3 scripts/build-demo.py --open
```

The bundle is `.build/Flow Demo.app`. It includes microphone and Speech usage
descriptions. Its endpoint is stored in its Info.plist. Override with the build
script's `--endpoint` option or `FLOW_DEMO_ENDPOINT` at launch. Subsequent rebuilds
can use `--skip-build` after `cargo build` and `swift build` have completed.

Speak requires macOS microphone and Speech Recognition authorization and an
available on-device English recognizer. No audio is silently sent to Apple's
cloud if on-device recognition is unavailable. Typed input exercises the same
formatting, streaming, memory and Send pipeline without those permissions.

## What is implemented

- The real speech recognizer streams partial words into the transcript. After a
  700 ms speech pause, Flow starts provisional personalized previews. On Finish,
  it waits briefly for the final speech revision and generates final drafts.
- Each recipient receives actual SSE token deltas from Workers AI. This is not
  a typewriter effect over a previously completed response. ASR revisions cancel
  older generations; provisional, cancelled and truncated drafts cannot be sent.
- Rust creates recipient-specific request tickets and records completed output.
  Send commits the exact edited wording to SQLite. There is no external message
  delivery from the harness. The architecture is Swift calling a Rust library
  through FFI; there is no separate Rust HTTP server.
- The UI exposes before/after edits, conversation context, evidence count and
  Forget. Only this person's examples in the same normalized context label are
  retrieved. A correction is not a permanent instruction or a global replacement.
- A lightweight deadline/numeric-token check keeps the original dictation when
  formatting drops those anchors, with an explicit UI label. This is conservative
  (e.g. writing `7` as `seven` can trigger it), not a complete semantic validator.
- The demo database is `~/Library/Application Support/flow/demo-conversations.db`.
  Synthetic histories never enter the production `flow.db`. Reset clears only
  the synthetic demo. Demo-only launch skips production hotkeys and analytics.
- The existing edit observer no longer learns on timeout, focus loss, or short
  text before Send. Its Return detection is still a heuristic for external apps;
  only the internal harness has an authoritative explicit Send receipt.

This is example retrieval and in-context personalization, **not reinforcement
learning or fine-tuning**. Context labels are currently entered explicitly; this
change does not implement semantic topic detection or cross-app identity matching.
The new streaming/memory path is exercised in the harness; the normal global
dictation hotkey still uses the existing buffered pipeline.

## Verify

```sh
cd flow-core
cargo test --offline --lib
cargo build --offline
cd ..
swift package clean # force relinking the external Rust archive
swift test
cd flow-worker-langgraph
npm test
npm run typecheck
cd ..
python3 scripts/verify-demo.py --output review/demo-learning.json
```

The live test uses a temporary in-memory database and synthetic messages. It
checks that a correction to Alex changes wording on an unseen sentence, keeps
its subject and date, stays out of Mum's prompt, allows emoji in a celebratory
context after removing one in a serious context, and disappears after Forget.
It records real provider outputs, token chunk counts, and request timings.
These timings are not microphone-to-paste measurements or a Wispr benchmark.
Model outputs can vary; a failed behavioral check must be inspected rather than
hidden by rerunning until it passes.

The automated tests do not verify live microphone permissions or the user's
spoken voice. Those need a brief microphone check on the recording Mac.

Before the upstream sync on 2026-10-17: all 44 worker tests, TypeScript checking, three Swift
tests and six new Rust demo tests passed. The full Rust suite returned 86 passed,
three failed and two ignored. The failures are Slack-mode expectations in
`apps::tests::test_app_tracker`, `apps::tests::test_suggested_modes` and
`modes::tests::test_mode_suggestions`, in modules unchanged by this work.
All seven live integration checks passed; observed results are saved in
`review/demo-learning.json`.

After syncing upstream on the same date, all 335 Rust tests (two additional
ignored), 47 worker tests, TypeScript checking and three Swift tests passed.
The main Swift app and FlowHelper built successfully. See
[upstream integration notes](upstream-sync.md) for the merge decisions.

## Recording direction: 15 seconds

Use actual Flow footage and your real voice, with Hyperframes as the video layer.

1. 0–3 s: Speak a short request; show Flow's actual recording indicator and live words.
2. 3–7 s: Track those words along three animated connections into recipient drafts.
   Brief history excerpts explain why each version differs. These connections
   are explanatory graphics, not a pretend product screen.
3. 7–11 s: Show a clear edit to an overly stiff request, followed by Send and a
   small receipt showing the exact edit and its recipient/context.
4. 11–15 s: A short new request uses the learned wording for that person. Keep
   the second input distinct so the viewer can see the learning generalizes.

Avoid a permanent "no emoji" example. Prefer an actual wording correction such
as `can u check the draft?` -> `got a sec to check the draft?`, then a new request
about slides. Show observed model results, not canned replacement messages.
If inference waits are shortened for the edit, mark the video as edited rather
than presenting it as an end-to-end latency demonstration.

Hyperframes source and capabilities checked on 2026-10-17:
https://github.com/heygen-com/hyperframes

The recording direction above describes the earlier three-recipient concept.
The completed Messages walkthrough is linked at the top of this page.
