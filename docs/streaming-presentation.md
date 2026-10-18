# Streaming presentation

`DictationPresentation.smooth` sits between genuine Rust/model events and the
native UI. Receiving continues independently; it is not slowed by display pacing.
Ordinary text appears one grapheme at a time about 40 ms apart (roughly 25
characters per second), with an extra 80 ms at commas/colons/semicolons and 160 ms
at sentence punctuation or newlines. Backlogs above 240 graphemes use small
catch-up frames capped at four graphemes, avoiding large visual jumps. Frames preserve
Unicode graphemes and metadata order; completion waits until all received text
has been presented. Errors discard queued presentation; cancellation stops both
tasks. Display time is deliberately different from model generation latency.

The normal app, isolated voice simulation and full Messages demo share this
adapter. The simulation's readable-playback toggle bypasses pacing when disabled.
Raw receipt events remain separate from presentation events in its report.

The native app still requires a safe Accessibility insertion path for incremental
writes into another app. Its existing final-paste fallback remains for rich drafts
without a writable selected-text range. The Messages demo uses the previously
verified Unicode-event writer to preserve existing native attachment objects.
It combines adjacent display graphemes into native writes of at most two
graphemes, flushing the final remainder and punctuation. This keeps small native
inserts reliable without speeding up the reveal. A buffered grapheme is never
treated as inserted: final verification compares the acknowledged native text to
the complete model output.

Verification: `swift test` includes burst splitting, Unicode fidelity, event order,
steady presentation intervals, bounded catch-up frames, cancellation and upstream
failure. All 34 Swift tests passed after the pacing adjustment. The Messages
runner records raw provider chunk count, display frame count, largest display
chunk, native write size/count and presentation duration separately. Its checks enforce
the slower reveal for short messages, a four-grapheme limit on display chunks
and a two-grapheme limit on native writes. Replays reuse existing screenshot
fixtures instead of rewriting source files that may already be attached.

The latest real Messages screenshot run passed all 13 checks, including swapping
an alternative file in and back: six genuine model chunks became 44 single-
grapheme display frames and 22 native writes over about 2.07 seconds. The prior
replay was 1.17 seconds. Final text and existing native attachments were preserved;
nothing was sent. See
[the scoped report](../review/imessage-full-demo-verification.json).
