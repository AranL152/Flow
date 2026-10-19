# Rewrite during recording

Previously, Flow streamed ASR captions during recording but did not start the
rewriting LLM until Stop. Batch-ASR fallback plus rewriting could leave the draft
empty for several seconds. Word pacing changed how output appeared, not when
inference began.

Cloud Auto on an English-locale Mac now also submits speech prefixes while the
microphone is recording. The client checks for a changed candidate every 350 ms
and keeps at most one preview request in flight. It requires three words and
holds the newest recognition word for more context. Recognized attachment cues
and pending Flow attach/find/search cues are withheld from message previews.
Ordinary Flow mentions remain ordinary speech. The authoritative worker still
parses commands on final dictation.

The new `flow_preview_rewrite_stream` FFI runs the same cloud provider with text,
current recipient category, scoped personalization and shortcut definitions. It
never stops capture, consumes saved audio, records an interaction, writes history,
stages an attachment or replaces pending send-learning state. Only genuine model
deltas are presented, one complete word at a time. A newer rewrite keeps the
previous phrase visible until it catches up, avoiding a reset to its first word.

Stop cancels speculative work. The existing final ASR, command/attachment and
rewriting pipeline validates the full utterance and reconciles only Flow's owned
range. Final text can revise provisional wording. Only validated completion
starts edit monitoring, and only Send can train the user's/contact's wording.
An attachment-only final result restores any provisional text to the original
draft before staging the attachment. User edits, selection/focus changes and
cancellation retain their existing guards.

Audio/waveform and duration timers now run on the main run loop in common modes,
so menu tracking cannot pause speech feeding. Cloud failures log only error and
frame/response counts, not transcripts. Cloud failure can still require recorded-
audio fallback; this change overlaps rewriting with speech, not a promise of
instant or consistently subsecond cloud responses. Preview requests add inference
usage. Apps without a safe writable Accessibility range retain final-paste fallback.

## Verification

All 52 Swift tests passed, including incomplete command withholding, ASR tail
handling, replacement behavior, Unicode word framing and edit protections. The
full Rust suite passed. A new fixture verifies that speculative rewriting uploads
text without audio, includes recipient context, streams real provider deltas,
preserves pending audio and learning state, and adds no history or style examples.
Its cancellation case also passed.

Run `python3 scripts/verify-live-rewrite.py` after building Rust and Swift. It
uses generated PCM paced in real time through the production Cloudflare speech
client and preview FFI. The recorded take passed five checks: nine speech
updates, three preview requests and 15 displayed model frames. The first LLM word
arrived 2,511 ms after speech started, before Stop at 7,706 ms. The provisional
output excluded the Flow command and cancellation produced no stale words after
Stop. This is one sample, not a median/p95 benchmark or a microphone test.
See [the report](../review/live-rewrite-verification.json).

A read-only native inspection also confirmed the currently focused Messages
composer supports the production safe live writer. It did not alter the draft.
Physical recording with the updated app still needs the user's microphone test.
The website's existing full Messages runner still uses its Stop-then-format
sequence; this new synthetic verifier checks the live cloud path separately.
