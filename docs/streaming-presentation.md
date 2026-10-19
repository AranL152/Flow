# Streaming presentation

`DictationPresentation.smooth` sits between genuine Rust/model events and the
native UI. Receiving continues independently at full speed. Text is presented
one complete whitespace-delimited word every 180 ms, with an extra 80 ms at
commas/colons/semicolons and 160 ms at sentence punctuation. A provider token
that ends mid-word waits for a word boundary, metadata or stream completion.
Words are never merged into larger catch-up bursts. Leading spaces, newlines,
punctuation and Unicode are preserved exactly; trailing whitespace flushes at
completion. Completion waits for all received text to be presented. Errors
discard queued presentation, and cancellation stops both tasks.

The normal app, isolated voice simulation and full Messages demo share this
adapter. The simulation's readable-playback toggle bypasses pacing when disabled.
Raw receipt events remain separate from presentation events in its report.

Speech captions also reveal complete words, 110 ms apart when a recognition
update contains several. Recognition revisions preserve the number of words
already shown. The complete white command remains visible for 220 ms before
the purple ripple. This does not insert raw speech into the recipient's draft.

The native app still requires a safe Accessibility insertion path for incremental
writes into another app. Its existing final-paste fallback remains for rich drafts
without a writable selected-text range. The Messages demo sends each complete
word in one native Unicode event, preserving existing attachment objects. Focus,
selection, draft text and attachment count are checked before each insertion,
and the acknowledged final text must equal the model output. It never sends.

Verification: all 48 Swift tests passed, including fragmented provider tokens,
Unicode fidelity, exact whitespace, long words, metadata order, paced word
intervals, cancellation and upstream failure. Fourteen native caption preview
checks passed; the complete white caption still precedes the purple effect.
The Messages runner records the actual display words and verifies one word per
frame, one native write per frame, presentation duration and preserved text and
attachments. See [the scoped run report](../review/imessage-full-demo-verification.json).

The latest real Messages run passed all 14 checks: six provider chunks became
seven whole-word updates and exactly seven native writes over 1.13 seconds.
The draft and existing attachments were preserved and a screenshot was appended
with alternatives. This take used recorded-audio ASR fallback and took 17.82
seconds overall; word pacing is not an inference-latency improvement. Nothing
was sent. The updated demo helper remains open without replacing the installed
app bundle or requesting new permissions.
