# Real model output in the native app

Normal recordings now use `/transcribe-stream` with the Auto cloud provider.
Whisper returns the raw speech first; the formatting model then sends real SSE
`delta` events. Rust validates the raw → delta → matching done sequence, forwards
the actual deltas over a C callback and exposes them as a Swift async stream.
No timer splits a completed response into pretend tokens.

The native Record tab shows the arriving draft and the recording bar changes to
“Writing…”. **Settings → General → Stream formatted output** controls this
behavior for the next recording. Live speech captions remain separate: those
show the on-device recognizer’s unformatted words while you speak; model output
begins after Stop and Whisper transcription.

At recording start Flow captures the focused text field and selection. Where the
app exposes a writable Accessibility value or selected-text range, tokens update
that captured span in place without a clipboard write or Return event. The
surrounding draft is preserved. Insertion stops if focus, selection or the text
changes, or the user types/clicks. A failed generation restores the original span
only if Flow still owns exactly the draft it wrote. Requests poll cancellation
while waiting for headers or further bytes and have a 90-second deadline.

Apps without writable Accessibility ranges show the real stream in Flow, then
receive one final paste if the target remains focused and no user input occurred.
Changing focus leaves the completed draft in Flow. Direct OpenAI transcription,
local transcription, retries and providers without a streaming implementation
retain their buffered behavior; this release streams the Auto worker path.

Only a validated completed generation becomes the baseline for the existing
edit-learning monitor. Intermediate drafts cannot become personalization
examples. The user edits and presses Send/Return; Flow never sends a message.
This uses saved recipient-specific examples, not reinforcement learning.

## Verification

```sh
cd flow-core
cargo test --offline
cd ..
swift test
python3 scripts/verify-dictation-stream.py
python3 scripts/verify-insertion.py
```

The live endpoint verifier synthesizes “Can you check the slides tomorrow” using
macOS Samantha, converts it to mono 16 kHz WAV and sends only that generated
fixture. It checks the Whisper sentence, actual multiple deltas, token order,
matching terminal text and absence of errors. See
[recorded SSE events](../review/dictation-stream-verification.json).

The new endpoint was deployed to the existing `base10-proxy` worker in Aran’s
Cloudflare account, version `779ed5d3-2def-4353-af4c-0c5e217cce00`. A live fixture
received raw speech at 1.2773 seconds, the first of three model chunks at 1.7686
seconds and completion at 1.9062 seconds. These are one run’s network timings,
not a benchmark or a sub-10 ms pipeline claim.

Unit/integration checks cover real callback delivery, raw speech retained for
send learning, cancelled streams not creating learnable partials, stalled-network
cancellation, terminal mismatch/errors, UTF-16 emoji offsets, surrounding text,
selection movement and external edits. The Rust suite has 343 passing tests (two Messages tests ignored), the
worker has 52 passing tests and the Swift package has 11.

The native insertion verifier creates its own NSTextView and uses the production
AX writer to check progressive writes, rollback and preserving user edits. On
this machine it reported **unavailable** because Accessibility permission is not
granted to the verification app. See
[actual permission result](../review/insertion-verification.json). It does not
open Messages or edit privacy settings. After granting this specific verification
bundle Accessibility permission, rerun to exercise those native checks. Actual
Messages composer support and physical microphone/hotkey use still require a
live take; compilation and range-model tests do not prove that integration.

Build the normal app with `python3 scripts/build-demo.py --native`. Build-only
verification does not install it or replace an existing `/Applications` copy.
